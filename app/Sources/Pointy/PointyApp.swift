import AppKit
import SwiftUI

/* Pointy — a menu-bar app. It is the always-on host the browser extension
   talks to (the job `node server/server.mjs` used to do from a terminal), it
   transcribes on device, and it installs and updates that extension. Menu bar
   only (LSUIElement) until its window is open. */

@main
struct PointyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    /// pointy's face as a template image, so the menu bar tints it like its neighbours.
    static let menuIcon: NSImage = {
        let image = NSImage(named: "MenuIcon") ?? NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Pointy")!
        image.isTemplate = true
        image.accessibilityDescription = "Pointy"
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(nsImage: Self.menuIcon)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// Clicking the app in Finder or Launchpad while it runs opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppModel.shared.show()
        return true
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text(model.serverStatus)
        if let last = model.lastSession {
            Divider()
            Text("Last session · \(last.marks) mark\(last.marks == 1 ? "" : "s") · \(last.date.formatted(date: .omitted, time: .shortened))")
            Button("Copy Brief Again") { model.copyLastBrief() }
        }
        Divider()
        Button("Open Pointy") { model.show(.home) }
        Button("Sessions…") { model.show(.sessions) }
        Button("Settings…") { model.show(.settings) }.keyboardShortcut(",")
        Divider()
        Button("Quit Pointy") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
