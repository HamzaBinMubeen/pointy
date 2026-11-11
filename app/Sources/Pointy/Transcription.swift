import AVFoundation
import Foundation
import Speech

/* On-device transcription, so speech never leaves the Mac and the browser never
   has to ask for the microphone page by page (a refused or forgotten prompt
   made for silent sessions).

   The overlay turns listening on and off (POST /listen) and polls for the live
   text (GET /listen/status) — the poll doubles as a heartbeat: if it stops, a
   tab closed mid-session, and listening stops with it. Finished phrases are
   kept with wall-clock times and merged into the session when it is saved, so
   the compiler aligns them with marks exactly as it did browser speech. */
final class Transcription {
    static let shared = Transcription()

    struct Segment { let at: Double; let text: String }   // `at` is epoch ms

    private let lock = NSLock()
    private var segments: [Segment] = []
    private var interim = ""
    private var tail = ""
    private var count = 0
    private var error: String?
    /// What the current run is doing, for the overlay and for diagnosing "no audio":
    /// idle · waiting-for-permission · preparing-model · listening · stopped.
    private var stage = "idle"
    private var level: Float = 0           // 0…1, smoothed input loudness
    private var buffers = 0                // audio buffers seen this run
    private var currentLevel: Float { lock.lock(); defer { lock.unlock() }; return level }
    private var wantListening = false
    private var lastHeartbeat = Date.distantPast
    private var run: Task<Void, Never>?
    private var stop: AsyncStream<Void>.Continuation?
    private var watchdog: Timer?

    static func isAvailable(_ engine: Preferences.Engine) -> Bool {
        guard engine.onDevice else { return true }
        if #available(macOS 26.0, *) {
            switch engine {
            case .appleSpeech: return SpeechTranscriber.isAvailable
            case .appleDictation: return true   // ships with macOS 26; languages are checked per locale
            case .browser: return true
            }
        }
        return false
    }

    // MARK: - control

    func setListening(_ on: Bool) {
        lock.lock()
        let changed = on != wantListening
        wantListening = on
        lastHeartbeat = Date()
        lock.unlock()
        guard changed else { return }
        if on { begin() } else { end() }
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        lastHeartbeat = Date()
        // `tail` is finished text only; `interim` is the phrase still being heard.
        return ["listening": wantListening, "tail": String(tail.suffix(220)), "interim": interim,
                "count": count, "error": error ?? NSNull(), "stage": stage, "level": level, "buffers": buffers,
                "mic": Self.micStatus]
    }

    /// Wait for the current run to finish finalising, then hand over the phrases
    /// that fall inside [from, to] (epoch ms). Called from the server queue.
    func drain(from: Double, to: Double, timeout: TimeInterval = 5) -> [Segment] {
        end()
        if let run {
            let done = DispatchSemaphore(value: 0)
            Task { await run.value; done.signal() }
            _ = done.wait(timeout: .now() + timeout)
        }
        lock.lock(); defer { lock.unlock() }
        let mine = segments.filter { $0.at >= from - 5000 && $0.at <= to + 5000 }
        segments.removeAll { $0.at <= to + 5000 }
        tail = ""; count = 0
        return mine
    }

    // MARK: - run

    private func begin() {
        let engine = Preferences.shared.engine
        guard engine.onDevice else { return }
        let previous = run
        let (signal, cont) = AsyncStream<Void>.makeStream()
        lock.lock(); stop = cont; error = nil; tail = ""; interim = ""; count = 0; buffers = 0; stage = "starting"; lock.unlock()
        run = Task.detached { [weak self] in
            await previous?.value               // one microphone run at a time
            guard let self else { return }
            if #available(macOS 26.0, *) {
                await self.listen(engine, until: signal)
            } else {
                self.fail("On-device transcription needs macOS 26.")
            }
        }
        DispatchQueue.main.async { self.startWatchdog() }
    }

    private func end() {
        lock.lock()
        wantListening = false
        let cont = stop
        stop = nil
        lock.unlock()
        cont?.yield(())
        cont?.finish()
    }

    /// The heartbeat: the overlay polls every second while it is open.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.lock.lock()
            let stale = self.wantListening && Date().timeIntervalSince(self.lastHeartbeat) > 6
            let idle = !self.wantListening
            self.lock.unlock()
            if stale { self.end() }
            if stale || idle { timer.invalidate() }
        }
    }

    private func fail(_ message: String) {
        lock.lock(); error = message; stage = "stopped"; level = 0; lock.unlock()
        NSLog("Pointy transcription: \(message)")
        TranscriptionLog.write("fail \(message)")
    }

    /// True, and the error set, when a listening run has had no audio at all.
    private func markSilent(device: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard buffers == 0, stage == "listening" else { return false }
        error = "No sound is coming from \(device). Pick another microphone in pointy's Settings."
        return true
    }

    private func set(stage new: String) {
        lock.lock(); stage = new; if new != "listening" { level = 0 }; lock.unlock()
    }

    /// Loudness of a buffer, eased so the overlay's meter moves smoothly.
    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let db = 20 * log10(max(rms, 0.000_01))            // -100…0
        let target = max(0, min(1, (db + 55) / 45))         // speech sits roughly at -45…-10 dB
        lock.lock(); level = level * 0.5 + target * 0.5; lock.unlock()
    }

    static var micStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "undetermined"
        }
    }

    /// Ask now, from the app's own window, rather than mid-session in the browser.
    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    private func record(final text: String, at: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        interim = ""
        guard !clean.isEmpty else { return }
        segments.append(Segment(at: at, text: clean))
        tail = String((tail + " " + clean).trimmingCharacters(in: .whitespaces).suffix(400))
        count += 1
    }

    private func record(interim text: String) {
        lock.lock(); interim = text; lock.unlock()
    }

    @available(macOS 26.0, *)
    private func listen(_ engine: Preferences.Engine, until signal: AsyncStream<Void>) async {
        if Self.micStatus == "undetermined" {
            set(stage: "waiting-for-permission")
            // A menu-bar app's prompt can open behind the browser; bring the window
            // forward so the one-time question is actually seen.
            DispatchQueue.main.async { AppModel.shared.show(.home) }
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return fail("Microphone is off for Pointy. Allow it in System Settings › Privacy & Security › Microphone.")
        }
        set(stage: "preparing-model")
        let locale = await Self.locale(for: engine)
        let clock = AudioClock()

        let module: any SpeechModule
        let consumer: Task<Void, Error>
        switch engine {
        case .appleDictation:
            let t = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            module = t
            consumer = Task { try await self.consume(t.results, clock) { String($0.text.characters) } }
        default:
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            module = t
            consumer = Task { try await self.consume(t.results, clock) { String($0.text.characters) } }
        }

        do {
            try await Self.prepareModel(module, locale)
            let analyzer = SpeechAnalyzer(modules: [module])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                consumer.cancel()
                return fail("No audio format available for \(engine.title).")
            }
            let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
            // Capture through AVCaptureSession: it opens exactly the chosen device and
            // hands over its real format. Retargeting AVAudioEngine's input node kept the
            // old device's format (44.1 kHz for a 48 kHz built-in mic), and a tap in the
            // wrong format receives nothing — that, not privacy, was the silence.
            var buffers = 0, dropped = 0, lastReport = Date()
            let mic = MicCapture(deviceUID: Preferences.shared.inputDeviceUID, target: format) { raw, converted in
                clock.markStart(frames: raw.frameLength, rate: raw.format.sampleRate)
                self.meter(raw)
                buffers += 1
                if let converted { feed.yield(AnalyzerInput(buffer: converted)) } else { dropped += 1 }
                if Date().timeIntervalSince(lastReport) > 5 {
                    lastReport = Date()
                    TranscriptionLog.write("audio \(buffers) buffers, \(dropped) not converted, level \(String(format: "%.2f", self.currentLevel))")
                }
                self.lock.lock(); self.buffers = buffers; self.lock.unlock()
            }
            guard let deviceName = mic.deviceName else {
                consumer.cancel()
                return fail("No microphone found. Check System Settings › Sound › Input, or pick one in pointy's Settings.")
            }
            TranscriptionLog.write("start \(engine.title) · \(locale.identifier) · mic \(deviceName) · model \(format)")
            try mic.start()
            try await analyzer.start(inputSequence: input)
            set(stage: "listening")

            // Permission granted and still no audio: the device is sending nothing
            // (asleep, switching modes, or taken by another app). Say which one.
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.markSilent(device: deviceName) {
                    TranscriptionLog.write("no audio from \(deviceName) after 3s")
                    DispatchQueue.main.async { AppModel.shared.micBlocked = true }
                }
            }

            for await _ in signal { break }
            set(stage: "stopped")
            TranscriptionLog.write("stop after \(buffers) buffers, \(dropped) not converted")

            mic.stop()
            feed.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            _ = try? await consumer.value
        } catch {
            consumer.cancel()
            TranscriptionLog.write("error \(error)")
            fail("\(engine.title) stopped: \(error.localizedDescription)")
        }
    }

    /// Reserve the language, then make sure its model is on disk. Without a
    /// reservation macOS doesn't keep the model for this app: transcription worked
    /// right after a fresh download and then quietly returned nothing.
    @available(macOS 26.0, *)
    static func prepareModel(_ module: any SpeechModule, _ locale: Locale) async throws {
        let reserved = (try? await AssetInventory.reserve(locale: locale)) ?? false
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let status = await AssetInventory.status(forModules: [module])
        TranscriptionLog.write("model \(locale.identifier): reserved \(reserved), \(status)")
    }

    @available(macOS 26.0, *)
    private func consume<S: AsyncSequence>(_ results: S, _ clock: AudioClock, text: @escaping (S.Element) -> String) async throws
    where S.Element: SpeechModuleResult {
        for try await result in results {
            if result.isFinal {
                TranscriptionLog.write("final [\(String(format: "%.1f", result.range.start.seconds))s] \(text(result))")
                record(final: text(result), at: clock.epochMs(at: result.range.start.seconds))
            } else {
                record(interim: text(result))
            }
        }
    }

    @available(macOS 26.0, *)
    static func locale(for engine: Preferences.Engine) async -> Locale {
        let wanted = Preferences.shared.speechLocale.isEmpty ? Locale.current : Locale(identifier: Preferences.shared.speechLocale)
        switch engine {
        case .appleDictation: return await DictationTranscriber.supportedLocale(equivalentTo: wanted) ?? Locale(identifier: "en-US")
        default: return await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? Locale(identifier: "en-US")
        }
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

/// Maps analyzer time (seconds since the first audio buffer) to wall-clock epoch ms,
/// which is the clock the extension stamps marks with.
private final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var start: Double?

    func markStart(frames: AVAudioFrameCount, rate: Double) {
        lock.lock(); defer { lock.unlock() }
        // The first buffer arrives once it is full, so its audio began that long ago.
        if start == nil { start = Date().timeIntervalSince1970 * 1000 - Double(frames) / rate * 1000 }
    }

    func epochMs(at seconds: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        return (start ?? Date().timeIntervalSince1970 * 1000) + seconds * 1000
    }
}

/// One microphone, opened with AVCaptureSession. Hands each buffer over twice: as
/// captured (for the level meter) and converted to the speech model's format.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pointy.mic")
    private let target: AVAudioFormat
    private let onBuffer: (AVAudioPCMBuffer, AVAudioPCMBuffer?) -> Void
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private(set) var deviceName: String?

    /// `deviceUID` is a CoreAudio device UID, which is also AVCaptureDevice's uniqueID;
    /// empty, or a device that has gone, means the system default.
    init(deviceUID: String, target: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer, AVAudioPCMBuffer?) -> Void) {
        self.target = target
        self.onBuffer = onBuffer
        super.init()
        let device = (deviceUID.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceUID)) ?? AVCaptureDevice.default(for: .audio)
        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        // Float, one channel, at the device's own rate: the meter reads floats, and
        // the converter takes it from there to whatever the model wants.
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true, AVNumberOfChannelsKey: 1]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        deviceName = device.localizedName
    }

    func start() throws {
        guard deviceName != nil else { throw StoreError("no microphone") }
        session.startRunning()
    }

    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return }
        // A Bluetooth headset can change rate mid-session; rebuild the converter if so.
        if converterSource != format {
            converter = AVAudioConverter(from: format, to: target)
            converterSource = format
        }
        onBuffer(buffer, converter.flatMap { Transcription.convert(buffer, with: $0, to: target) })
    }
}
