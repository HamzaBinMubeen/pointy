import Speech
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var model: AppModel
    @StateObject private var speech = SpeechModelStatus()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Text("Settings").font(DS.Font.title).foregroundStyle(DS.Colors.ink)

                Section(title: "Sessions") {
                    Row(title: "Keep the last", detail: "Older sessions are deleted first.") {
                        Picker("", selection: $prefs.keepCount) {
                            ForEach(Preferences.keepOptions, id: \.self) { Text("\($0) sessions").tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                    Row(title: "Delete after", detail: "Sessions live in a temporary folder.", last: true) {
                        Picker("", selection: $prefs.maxAgeHours) {
                            ForEach(Preferences.ageOptions, id: \.self) { Text(Preferences.ageLabel($0)).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
                .onChange(of: prefs.keepCount) { _, _ in SessionStore.shared.prune() }
                .onChange(of: prefs.maxAgeHours) { _, _ in SessionStore.shared.prune() }

                Section(title: "Transcription") {
                    ForEach(Array(Preferences.Engine.allCases.enumerated()), id: \.element) { i, engine in
                        EngineRow(engine: engine, selected: prefs.engine == engine,
                                  available: Transcription.isAvailable(engine),
                                  last: i == Preferences.Engine.allCases.count - 1 && !prefs.engine.onDevice) {
                            prefs.engineRaw = engine.rawValue
                            speech.refresh(engine)
                        }
                    }
                    if prefs.engine.onDevice {
                        Row(title: "Microphone", detail: micDetail) {
                            Picker("", selection: $prefs.inputDeviceUID) {
                                Text("System default").tag("")
                                ForEach(devices) { Text($0.name).tag($0.uid) }
                            }.labelsHidden().frame(width: 200)
                        }
                        Row(title: "Language") {
                            Picker("", selection: $prefs.speechLocale) {
                                Text("Same as Mac").tag("")
                                ForEach(speech.locales, id: \.identifier) { loc in
                                    Text(Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier).tag(loc.identifier)
                                }
                            }.labelsHidden().frame(width: 200)
                        }
                        .onChange(of: prefs.speechLocale) { _, _ in speech.refresh(prefs.engine) }
                        Row(title: "Speech model", detail: speech.modelDetail, last: true) {
                            if speech.canDownload {
                                Button(speech.downloading ? "Downloading…" : "Download now") { speech.download(prefs.engine) }
                                    .buttonStyle(QuietButtonStyle()).disabled(speech.downloading).fixedSize()
                            }
                        }
                    }
                }

                Section(title: "Appearance") {
                    HStack(spacing: DS.Space.md) {
                        ForEach(Preferences.Appearance.allCases) { a in
                            AppearanceTile(appearance: a, selected: prefs.appearance == a) {
                                prefs.appearanceRaw = a.rawValue
                            }
                        }
                    }
                    .padding(DS.Space.lg)
                }

                Section(title: "General") {
                    Row(title: "Start with your Mac") {
                        Toggle("", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    Row(title: "Sound when a brief is saved", last: true) {
                        Toggle("", isOn: $prefs.playSound).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }

                Section(title: "About") {
                    Row(title: "Pointy", detail: "App") {
                        Text("v\(appVersion)").font(DS.Font.callout).foregroundStyle(DS.Colors.inkSecondary)
                    }
                    Row(title: "Browser extension", detail: model.extensionConnected ? "Connected, updates itself" : "Not connected") {
                        Text(model.extensionVersion.map { "v\($0)" } ?? "—").font(DS.Font.callout).foregroundStyle(DS.Colors.inkSecondary)
                    }
                    Row(title: "Sessions folder", last: true) {
                        Button("Show in Finder") {
                            SessionStore.shared.linkSessionsFolder()
                            NSWorkspace.shared.open(SessionStore.shared.root)
                        }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { speech.refresh(prefs.engine) }
    }

    private var devices: [InputDevice] { InputDevice.all }

    /// Say which mic "System default" is today, and warn off Bluetooth headsets.
    private var micDetail: String {
        let name = prefs.inputDeviceUID.isEmpty ? (InputDevice.defaultName ?? "") : (InputDevice.find(uid: prefs.inputDeviceUID)?.name ?? "")
        let bluetooth = InputDevice.isBluetooth(name: name)
        if prefs.inputDeviceUID.isEmpty { return bluetooth ? "Now \(name). Headset mics sound like a phone call; the Mac's own mic is clearer." : "Now \(name)." }
        return bluetooth ? "Headset mics sound like a phone call; the Mac's own mic is clearer." : "Used only while you annotate."
    }

    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

// MARK: - pieces

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.inkSecondary)
                .padding(.leading, 4)
            Card(padding: 0) { VStack(spacing: 0) { content } }
        }
    }
}

private struct Row<Control: View>: View {
    let title: String
    var detail: String? = nil
    var last = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(DS.Colors.ink)
                if let detail { Text(detail).font(DS.Font.caption).foregroundStyle(DS.Colors.inkTertiary) }
            }
            Spacer()
            control
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(DS.Colors.hairline).frame(height: 1).padding(.leading, DS.Space.lg) }
        }
    }
}

private struct EngineRow: View {
    let engine: Preferences.Engine
    let selected: Bool
    let available: Bool
    var last = false
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: DS.Space.md) {
                ZStack {
                    Circle().strokeBorder(selected ? DS.Colors.accent : DS.Colors.inkTertiary, lineWidth: 1.5).frame(width: 18, height: 18)
                    if selected { Circle().fill(DS.Colors.accent).frame(width: 10, height: 10) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(engine.title).font(.system(size: 14)).foregroundStyle(DS.Colors.ink)
                        Text(engine.onDevice ? "On this Mac" : "Cloud")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(engine.onDevice ? DS.Colors.success : DS.Colors.inkSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(engine.onDevice ? DS.Colors.successSoft : DS.Colors.well, in: Capsule())
                    }
                    Text(available ? engine.detail : "Not available on this Mac.").font(DS.Font.caption).foregroundStyle(DS.Colors.inkTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, DS.Space.lg)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(DS.Colors.hairline).frame(height: 1).padding(.leading, 46) }
        }
    }
}

private struct AppearanceTile: View {
    let appearance: Preferences.Appearance
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: DS.Space.sm) {
                preview
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .strokeBorder(selected ? DS.Colors.accent : DS.Colors.hairline, lineWidth: selected ? 2 : 1))
                Text(appearance.label).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DS.Colors.ink : DS.Colors.inkSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var preview: some View {
        switch appearance {
        case .light: Mini(dark: false)
        case .dark: Mini(dark: true)
        case .system:
            HStack(spacing: 0) { Mini(dark: false); Mini(dark: true) }
        }
    }

    /// A tiny window: sidebar strip, a title bar and an orange mark.
    private struct Mini: View {
        let dark: Bool
        var body: some View {
            let p = DS.palette
            let paper = Color(nsColor: NSColor(hex: dark ? p.background.dark : p.background.light))
            let side = Color(nsColor: NSColor(hex: dark ? p.sidebar.dark : p.sidebar.light))
            let line = dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
            HStack(spacing: 0) {
                side.frame(width: 22)
                ZStack(alignment: .topLeading) {
                    paper
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(line).frame(width: 34, height: 5)
                        Capsule().fill(line).frame(width: 52, height: 4)
                        RoundedRectangle(cornerRadius: 2).strokeBorder(Color(nsColor: NSColor(hex: dark ? p.accent.dark : p.accent.light)), lineWidth: 1.5)
                            .frame(width: 30, height: 16)
                    }
                    .padding(9)
                }
            }
        }
    }
}

/// Which languages the chosen on-device engine supports, and whether its model
/// is on this Mac yet. Models download on first use anyway; the button just
/// lets you do it ahead of time.
final class SpeechModelStatus: ObservableObject {
    @Published var locales: [Locale] = []
    @Published var modelDetail = "Checking…"
    @Published var canDownload = false
    @Published var downloading = false

    func refresh(_ engine: Preferences.Engine) {
        guard engine.onDevice else { return }
        guard #available(macOS 26.0, *) else { return }
        Task { @MainActor in
            let locale = await locale(for: engine)
            let module = makeModule(engine, locale)
            let status = await AssetInventory.status(forModules: [module])
            let supported = engine == .appleDictation ? await DictationTranscriber.supportedLocales : await SpeechTranscriber.supportedLocales
            locales = supported
                .sorted { (Locale.current.localizedString(forIdentifier: $0.identifier) ?? "") < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? "") }
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            switch status {
            case .installed: modelDetail = "\(name) model is on this Mac."; canDownload = false
            case .downloading: modelDetail = "Downloading the \(name) model…"; canDownload = false
            case .supported: modelDetail = "\(name) model downloads on first use."; canDownload = true
            default: modelDetail = "\(name) isn't supported by \(engine.title)."; canDownload = false
            }
        }
    }

    func download(_ engine: Preferences.Engine) {
        guard #available(macOS 26.0, *) else { return }
        downloading = true
        Task { @MainActor in
            let module = makeModule(engine, await locale(for: engine))
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                modelDetail = "Download failed: \(error.localizedDescription)"
            }
            downloading = false
            refresh(engine)
        }
    }

    @available(macOS 26.0, *)
    private func makeModule(_ engine: Preferences.Engine, _ locale: Locale) -> any SpeechModule {
        engine == .appleDictation
            ? DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            : SpeechTranscriber(locale: locale, preset: .transcription)
    }

    @available(macOS 26.0, *)
    private func locale(for engine: Preferences.Engine) async -> Locale {
        let wanted = Preferences.shared.speechLocale.isEmpty ? Locale.current : Locale(identifier: Preferences.shared.speechLocale)
        let match = engine == .appleDictation
            ? await DictationTranscriber.supportedLocale(equivalentTo: wanted)
            : await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        return match ?? Locale(identifier: "en-US")
    }
}
