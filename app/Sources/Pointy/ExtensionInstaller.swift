import AppKit
import Foundation

/* Getting the extension into the browser, and keeping it current.

   What macOS browsers allow (Chrome and Edge docs, checked 2026-11-11): another
   app may only install an extension that is LISTED in the Chrome Web Store or
   Edge Add-ons — by dropping a JSON file in the browser's "External Extensions"
   folder — and the browser then asks the user to confirm. Local .crx installs
   have been blocked on Mac since Chrome 44.

   So there are two paths:
   - Listed (once storeIDs are filled in): write that JSON file, the browser
     prompts on next launch, and the store keeps it updated.
   - Unlisted (today): copy the extension to a fixed folder and have the user
     load it unpacked ONCE. After that this app rewrites the folder whenever it
     is updated, and the extension reloads itself from it (background.js asks
     /version and calls chrome.runtime.reload() when this copy is newer).
*/
struct Browser: Identifiable, Hashable {
    let id: String          // bundle identifier
    let name: String
    let extensionsPage: String
    var shortcutsPage: String { extensionsPage + "/shortcuts" }
    let supportDir: String  // under ~/Library/Application Support
    let storeKey: StoreKey

    enum StoreKey { case chrome, edge }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static let known: [Browser] = [
        Browser(id: "com.google.Chrome", name: "Google Chrome", extensionsPage: "chrome://extensions", supportDir: "Google/Chrome", storeKey: .chrome),
        Browser(id: "com.microsoft.edgemac", name: "Microsoft Edge", extensionsPage: "edge://extensions", supportDir: "Microsoft Edge", storeKey: .edge),
        Browser(id: "com.brave.Browser", name: "Brave", extensionsPage: "brave://extensions", supportDir: "BraveSoftware/Brave-Browser", storeKey: .chrome),
        Browser(id: "company.thebrowser.Browser", name: "Arc", extensionsPage: "chrome://extensions", supportDir: "Arc/User Data", storeKey: .chrome),
    ]

    static var installed: [Browser] { known.filter { $0.appURL != nil } }
}

final class ExtensionInstaller {
    /// Store listing IDs. Empty until the extension is published; filling one in
    /// switches that store's browsers to one-click install with store updates.
    static let storeIDs: [Browser.StoreKey: String] = [:]
    private static let updateURLs: [Browser.StoreKey: String] = [
        .chrome: "https://clients2.google.com/service/update2/crx",
        .edge: "https://edge.microsoft.com/extensionwebstorebase/v1/crx",
    ]

    static let folder = SessionStore.support.appendingPathComponent("Extension", isDirectory: true)

    static var bundledFolder: URL? { Bundle.main.url(forResource: "extension", withExtension: nil) }
    static var bundledVersion: String? { bundledFolder.flatMap(version(in:)) }

    static func version(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    /// Put the bundled extension in the fixed folder when it is missing or a
    /// different version. Swapped in whole, so the browser never reads half a copy.
    func syncBundledExtension() {
        let fm = FileManager.default
        guard let source = Self.bundledFolder, let want = Self.bundledVersion else { return }
        if Self.version(in: Self.folder) == want { return }
        do {
            try fm.createDirectory(at: SessionStore.support, withIntermediateDirectories: true)
            let staging = SessionStore.support.appendingPathComponent("Extension.new", isDirectory: true)
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: Self.folder.path) {
                _ = try fm.replaceItemAt(Self.folder, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: Self.folder)
            }
        } catch {
            NSLog("Pointy: could not update the extension folder: \(error)")
        }
    }

    func isListed(for browser: Browser) -> Bool { Self.storeIDs[browser.storeKey] != nil }

    /// Listed: register it with the browser, which asks the user to enable it.
    /// Unlisted: open the extensions page with the folder path on the clipboard.
    func install(in browser: Browser) {
        if let id = Self.storeIDs[browser.storeKey], let update = Self.updateURLs[browser.storeKey] {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(browser.supportDir).appendingPathComponent("External Extensions")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let json = try? JSONSerialization.data(withJSONObject: ["external_update_url": update])
            try? json?.write(to: dir.appendingPathComponent("\(id).json"))
            open(browser, browser.storeKey == .edge
                 ? "https://microsoftedge.microsoft.com/addons/detail/\(id)"
                 : "https://chromewebstore.google.com/detail/\(id)")
            return
        }
        syncBundledExtension()
        Clipboard.set(Self.folder.path)
        open(browser, browser.extensionsPage)
    }

    /// Chromium browsers ignore their own pages (edge://, chrome://) when another
    /// app opens them as a URL — Edge just came to the front on its current tab.
    /// Asking the browser over AppleScript to make the tab works; macOS asks the
    /// user once to let Pointy control that browser.
    func openPage(in browser: Browser, _ address: String) { open(browser, address) }

    private func open(_ browser: Browser, _ address: String) {
        if !address.hasPrefix("https://") {
            let script = """
                tell application id "\(browser.id)"
                    activate
                    tell front window to make new tab with properties {URL:"\(address)"}
                end tell
                """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil { return }
            NSLog("Pointy: could not open \(address) in \(browser.name): \(error!)")
        }
        guard let app = browser.appURL, let url = URL(string: address) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
