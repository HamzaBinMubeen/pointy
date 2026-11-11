import AppKit
import ServiceManagement
import SwiftUI

struct LastSession {
    let dir: URL
    let marks: Int
    let date: Date
    let brief: String
}

enum Tab: Hashable { case home, sessions, shortcuts, settings }

/// Everything the menu and the window show. Written on the main thread only.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var serverStatus = "Starting…"
    @Published var serverOK = false
    @Published var lastSession: LastSession?
    @Published var extensionVersion: String?
    /// The shortcut the browser gave the extension, as it reports it ("⌃⇧P").
    /// Empty: the browser assigned none — it skips a key it uses itself.
    @Published var extensionShortcut: String?

    /// Keycaps for the shortcut: the real one once the extension reports it.
    var shortcutKeys: [String] {
        let s = (extensionShortcut?.isEmpty == false ? extensionShortcut! : "⌃⇧P")
        return s.map(String.init)
    }
    var shortcutMissing: Bool { extensionShortcut == "" }

    func openShortcutSettings() {
        if let browser = Browser.installed.first { installer.openPage(in: browser, browser.shortcutsPage) }
    }
    @Published var opensAtLogin = SMAppService.mainApp.status == .enabled
    @Published var commandInstalled = ClaudeCommand.isInstalled
    @Published var micStatus = Transcription.micStatus
    /// Permission granted, yet the microphone sent no audio (see Transcription).
    @Published var micBlocked = false
    @Published var tab: Tab = .home
    @AppStorage("firstNoteDone") var firstNoteDone = false
    @AppStorage("celebrated") var celebrated = false

    let installer = ExtensionInstaller()
    private var server: HostServer?
    private var window: NSWindow?

    var extensionConnected: Bool { extensionVersion != nil }

    /// The things to do once, in order. All done → the reward.
    var setupDone: Bool { setupSteps.allSatisfy { $0 } }

    /// The microphone only matters when the app does the listening.
    var needsMic: Bool { Preferences.shared.engine.onDevice }
    var micOK: Bool { !needsMic || (micStatus == "granted" && !micBlocked) }
    var setupSteps: [Bool] { [serverOK, extensionConnected && !shortcutMissing, micOK, commandInstalled, firstNoteDone, opensAtLogin] }

    func allowMicrophone() {
        if micBlocked { micBlocked = false; tab = .settings; return }   // the fix is a different mic
        if micStatus == "undetermined" {
            Transcription.requestMicrophone { [weak self] _ in self?.micStatus = Transcription.micStatus }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)    // denied before: only System Settings can turn it back on
        }
    }

    func start() {
        Preferences.shared.applyAppearance()
        installer.syncBundledExtension()
        SessionStore.shared.linkSessionsFolder()
        SessionStore.shared.prune()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in SessionStore.shared.prune() }
        if !SessionLibrary.shared.sessions.isEmpty { firstNoteDone = true }

        let server = HostServer(port: 7777)
        server.onState = { [weak self] ok, text in
            DispatchQueue.main.async { self?.serverOK = ok; self?.serverStatus = text }
        }
        server.onExtensionSeen = { [weak self] version, shortcut in
            DispatchQueue.main.async {
                if self?.extensionVersion != version { self?.extensionVersion = version }
                if let shortcut, self?.extensionShortcut != shortcut { self?.extensionShortcut = shortcut }
            }
        }
        server.onSession = { [weak self] session in
            DispatchQueue.main.async {
                self?.lastSession = session
                self?.firstNoteDone = true
                SessionLibrary.shared.reload()
            }
        }
        server.start()
        self.server = server

        if !UserDefaults.standard.bool(forKey: "setupShown") {
            UserDefaults.standard.set(true, forKey: "setupShown")
            show(.home)
        }
    }

    // MARK: - window

    func show(_ tab: Tab? = nil) {
        if let tab { self.tab = tab }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Pointy"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 520)
            window.contentView = NSHostingView(rootView: RootView()
                .environmentObject(self)
                .environmentObject(Preferences.shared)
                .environmentObject(SessionLibrary.shared))
            window.center()
            window.setFrameAutosaveName("PointyMain")
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                NSApp.setActivationPolicy(.accessory)   // back to menu bar only
            }
            self.window = window
        }
        SessionLibrary.shared.reload()
        micStatus = Transcription.micStatus
        NSApp.setActivationPolicy(.regular)             // a Dock icon while the window is open
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - actions

    func copyLastBrief() {
        guard let brief = lastSession?.brief ?? SessionLibrary.shared.sessions.first.map({ SessionStore.payload(dir: $0.dir, brief: $0.brief) }) else { return }
        Clipboard.set(brief)
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Pointy: login item change failed: \(error)")
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func installCommand() {
        ClaudeCommand.install()
        commandInstalled = ClaudeCommand.isInstalled
    }
}

enum Clipboard {
    static func set(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The /ui command for Claude Code, installed user-wide so it works in every project.
enum ClaudeCommand {
    static let target = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/commands/ui.md")

    static var bundled: URL? { Bundle.main.url(forResource: "ui", withExtension: "md") }

    static var isInstalled: Bool {
        guard let bundled, let a = try? Data(contentsOf: bundled), let b = try? Data(contentsOf: target) else { return false }
        return a == b
    }

    static func install() {
        guard let bundled else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // removeItem on a symlink removes the link, not what it points at.
        try? fm.removeItem(at: target)
        try? fm.copyItem(at: bundled, to: target)
    }
}
