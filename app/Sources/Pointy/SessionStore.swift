import AppKit
import Foundation
import JavaScriptCore

/* Sessions live in the system temp folder ($TMPDIR/Pointy), which macOS clears
   on its own; on top of that, Settings caps how many are kept and for how long,
   applied on every save, on launch and hourly. Two stable links give /ui a
   fixed path to read:

     ~/Library/Application Support/Pointy/Sessions  →  $TMPDIR/Pointy
     $TMPDIR/Pointy/latest                          →  the newest session
*/
final class SessionStore {
    static let shared = SessionStore()

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pointy", isDirectory: true)
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pointy", isDirectory: true)
    private let compiler = BriefCompiler()

    func save(_ body: Data, speech extra: [Transcription.Segment] = []) throws -> LastSession {
        let fm = FileManager.default
        guard var bundle = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw StoreError("session is not a JSON object")
        }
        // The id becomes a folder name; keep it to the timestamp alphabet.
        let rawId = bundle["id"] as? String ?? ""
        let id = rawId.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
            ? rawId : ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let shots = bundle["shots"] as? [String: String] ?? [:]
        for (name, dataURL) in shots {
            guard let comma = dataURL.range(of: ";base64,"),
                  let bytes = Data(base64Encoded: String(dataURL[comma.upperBound...])) else { continue }
            try bytes.write(to: dir.appendingPathComponent((name as NSString).lastPathComponent))
        }

        // Speech transcribed on this Mac joins whatever the browser sent (typed
        // notes, or browser speech); the compiler orders it all by `at`.
        if !extra.isEmpty {
            let started = bundle["startedAt"] as? Double ?? 0
            var speech = bundle["speech"] as? [[String: Any]] ?? []
            speech += extra.map { ["t": $0.at - started, "at": $0.at, "text": $0.text, "source": "mac"] }
            bundle["speech"] = speech
        }

        // Everything but the image bytes, for re-compiling later — and all the
        // compiler needs, so the megabytes of base64 never reach JavaScriptCore.
        bundle["shots"] = shots.keys.sorted()
        let slim = try JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
        try slim.write(to: dir.appendingPathComponent("notes.json"))

        let brief = try compiler.compile(String(decoding: slim, as: UTF8.self))
        try Data(brief.utf8).write(to: dir.appendingPathComponent("BRIEF.md"))
        relink(root.appendingPathComponent("latest"), to: id)
        linkSessionsFolder()

        let payload = Self.payload(dir: dir, brief: brief)
        let marks = (bundle["notes"] as? [Any])?.count ?? 0
        DispatchQueue.main.async {
            Clipboard.set(payload)
            if Preferences.shared.playSound { NSSound(named: "Glass")?.play() }
        }
        prune(keeping: dir)
        return LastSession(dir: dir, marks: marks, date: Date(), brief: payload)
    }

    /// What goes on the clipboard: the brief, prefixed with where its screenshots are.
    static func payload(dir: URL, brief: String) -> String {
        "<!-- Pointy. Screenshots referenced below are in: \(dir.path)\n" +
            "     Equivalent: run /ui in Claude Code, which reads the file and the images. -->\n\n" + brief
    }

    /// Apply the retention settings: older than the age limit goes, then anything
    /// past the newest N. `keeping` is never deleted (the session just saved).
    func prune(keeping: URL? = nil) {
        let prefs = Preferences.shared
        let cutoff = Date().addingTimeInterval(-prefs.maxAgeHours * 3600)
        let dirs = sessionFolders()
        for (index, item) in dirs.enumerated() where item.url.standardizedFileURL != keeping?.standardizedFileURL {
            if item.created < cutoff || index >= prefs.keepCount { delete(item.url) }
        }
        DispatchQueue.main.async { SessionLibrary.shared.reload() }
    }

    /// Session folders, newest first.
    func sessionFolders() -> [(url: URL, created: Date)] {
        let keys: [URLResourceKey] = [.creationDateKey, .isSymbolicLinkKey, .isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        return items.compactMap { url -> (URL, Date)? in
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isSymbolicLink != true, v?.isDirectory == true else { return nil }
            return (url, v?.creationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .map { (url: $0.0, created: $0.1) }
    }

    func delete(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    func linkSessionsFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        relink(Self.support.appendingPathComponent("Sessions"), to: root.path)
    }

    /// Replace a symlink. removeItem deletes the link itself, never its target —
    /// the Node server's rmSync got exactly this wrong and froze `latest`.
    private func relink(_ link: URL, to destination: String) {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == destination { return }
        try? fm.removeItem(at: link)
        do { try fm.createSymbolicLink(atPath: link.path, withDestinationPath: destination) }
        catch { NSLog("Pointy: could not link \(link.path): \(error)") }
    }
}

struct StoreError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Runs server/brief.cjs — the same compiler the Node server uses — in JavaScriptCore.
final class BriefCompiler {
    private let context: JSContext
    private var lastError: String?
    private let lock = NSLock()

    init() {
        context = JSContext()
        let log: @convention(block) (String) -> Void = { NSLog("brief.cjs: %@", $0) }
        context.setObject(log, forKeyedSubscript: "__log" as NSString)
        context.evaluateScript("""
            var console = { log: function () { __log(Array.prototype.join.call(arguments, " ")) } };
            console.error = console.log; console.warn = console.log;
            """)
        context.exceptionHandler = { [weak self] _, exception in self?.lastError = exception?.toString() }
        if let url = Bundle.main.url(forResource: "brief", withExtension: "cjs"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            context.evaluateScript(source, withSourceURL: url)
        } else {
            lastError = "brief.cjs is missing from the app bundle"
        }
    }

    func compile(_ json: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let lastError, context.objectForKeyedSubscript("compile")?.isUndefined ?? true { throw StoreError(lastError) }
        lastError = nil
        context.setObject(json, forKeyedSubscript: "__bundle" as NSString)
        let result = context.evaluateScript("compile(JSON.parse(__bundle))")
        if let lastError { throw StoreError("brief.cjs: \(lastError)") }
        return result?.toString() ?? ""
    }
}

// MARK: - history

/// One saved session, as the Sessions tab lists it.
struct SessionSummary: Identifiable, Hashable {
    let id: String
    let dir: URL
    let date: Date
    let duration: TimeInterval
    let marks: Int
    let pages: [String]
    let said: String
    let crops: [URL]

    var briefURL: URL { dir.appendingPathComponent("BRIEF.md") }
    var brief: String { (try? String(contentsOf: briefURL, encoding: .utf8)) ?? "" }
    var host: String { pages.first.flatMap { URL(string: $0)?.host } ?? "page" }
}

final class SessionLibrary: ObservableObject {
    static let shared = SessionLibrary()
    @Published private(set) var sessions: [SessionSummary] = []

    func reload() {
        sessions = SessionStore.shared.sessionFolders()
            .compactMap { Self.summary(of: $0.url, created: $0.created) }
            .sorted { $0.date > $1.date }
    }

    func delete(_ session: SessionSummary) {
        SessionStore.shared.delete(session.dir)
        reload()
    }

    private static func summary(of dir: URL, created: Date) -> SessionSummary? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("notes.json")),
              let b = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // A typed note is sent again as an `amend` of its mark; it is not a mark.
        let notes = (b["notes"] as? [[String: Any]] ?? []).filter { $0["amend"] as? Bool != true }
        let speech = (b["speech"] as? [[String: Any]] ?? []).sorted { ($0["at"] as? Double ?? 0) < ($1["at"] as? Double ?? 0) }
        let started = b["startedAt"] as? Double
        let ended = b["endedAt"] as? Double
        var pages: [String] = []
        for n in notes { if let u = n["url"] as? String, !pages.contains(u) { pages.append(u) } }
        let crops = notes.compactMap { ($0["crop"] as? String) ?? ($0["shot"] as? String) }
            .map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return SessionSummary(
            id: dir.lastPathComponent, dir: dir,
            date: started.map { Date(timeIntervalSince1970: $0 / 1000) } ?? created,
            duration: (ended ?? 0) > (started ?? 0) ? ((ended ?? 0) - (started ?? 0)) / 1000 : 0,
            marks: notes.count, pages: pages,
            said: speech.compactMap { $0["text"] as? String }.joined(separator: " "),
            crops: crops)
    }
}
