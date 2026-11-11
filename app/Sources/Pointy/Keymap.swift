import AppKit
import SwiftUI

/// One key combination. `key` uses the browser's KeyboardEvent.key, lower-cased
/// ("v", "enter", "backspace", "arrowleft", "space"), so the overlay can match it
/// directly.
struct KeyCombo: Codable, Equatable, Hashable {
    var key: String
    var cmd = false
    var shift = false
    var alt = false
    var ctrl = false

    /// What a keycap shows: modifiers in Apple's order, then the key.
    var symbols: [String] {
        var out: [String] = []
        if ctrl { out.append("⌃") }
        if alt { out.append("⌥") }
        if shift { out.append("⇧") }
        if cmd { out.append("⌘") }
        out.append(Self.keySymbol(key))
        return out
    }
    var label: String { symbols.joined() }

    static func keySymbol(_ key: String) -> String {
        switch key {
        case "enter": return "↩"
        case "backspace": return "⌫"
        case "delete": return "⌦"
        case "space": return "Space"
        case "tab": return "⇥"
        case "arrowleft": return "←"
        case "arrowright": return "→"
        case "arrowup": return "↑"
        case "arrowdown": return "↓"
        default: return key.uppercased()
        }
    }

    /// From a key press in the recorder. Nil for keys a shortcut can't use (Esc,
    /// or a lone modifier).
    init?(event: NSEvent) {
        let names: [UInt16: String] = [36: "enter", 76: "enter", 51: "backspace", 117: "delete", 49: "space", 48: "tab",
                                       123: "arrowleft", 124: "arrowright", 125: "arrowdown", 126: "arrowup"]
        if event.keyCode == 53 { return nil }   // Esc stays "cancel"
        guard let key = names[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return nil }
        let flags = event.modifierFlags
        self.init(key: key, cmd: flags.contains(.command), shift: flags.contains(.shift),
                  alt: flags.contains(.option), ctrl: flags.contains(.control))
    }

    init(key: String, cmd: Bool = false, shift: Bool = false, alt: Bool = false, ctrl: Bool = false) {
        self.key = key; self.cmd = cmd; self.shift = shift; self.alt = alt; self.ctrl = ctrl
    }
}

/// Every key the overlay listens for, besides Esc (always "cancel") and the
/// open-on-a-page shortcut (which the browser owns).
enum KeyAction: String, CaseIterable, Codable, Identifiable {
    case select, rect, oval, arrow, pass, note, undo, over, done
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .rect: return "Rectangle"
        case .oval: return "Oval"
        case .arrow: return "Arrow"
        case .pass: return "Use the page"
        case .note: return "Type a note"
        case .undo: return "Undo"
        case .over: return "Start over"
        case .done: return "Done"
        }
    }

    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .rect: return "rectangle"
        case .oval: return "oval"
        case .arrow: return "arrow.up.right"
        case .pass: return "hand.raised"
        case .note: return "text.bubble"
        case .undo: return "arrow.uturn.backward"
        case .over: return "trash"
        case .done: return "checkmark"
        }
    }

    var isTool: Bool { [.select, .rect, .oval, .arrow, .pass].contains(self) }

    var defaultCombo: KeyCombo {
        switch self {
        case .select: return KeyCombo(key: "v")
        case .rect: return KeyCombo(key: "r")
        case .oval: return KeyCombo(key: "o")
        case .arrow: return KeyCombo(key: "a")
        case .pass: return KeyCombo(key: "h")
        case .note: return KeyCombo(key: "t")
        case .undo: return KeyCombo(key: "z", cmd: true)
        case .over: return KeyCombo(key: "backspace", cmd: true)
        case .done: return KeyCombo(key: "enter", cmd: true)
        }
    }
}

/// The user's keys, saved in UserDefaults and sent to the overlay with /version.
final class Keymap: ObservableObject {
    static let shared = Keymap()
    @Published private(set) var combos: [KeyAction: KeyCombo]

    private init() {
        var map = Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { ($0, $0.defaultCombo) })
        if let data = UserDefaults.standard.data(forKey: "keymap"),
           let saved = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (k, v) in saved { if let a = KeyAction(rawValue: k) { map[a] = v } }
        }
        combos = map
    }

    func combo(_ action: KeyAction) -> KeyCombo { combos[action] ?? action.defaultCombo }

    /// The action already using this combination, if any (other than `action`).
    func conflict(_ combo: KeyCombo, for action: KeyAction) -> KeyAction? {
        combos.first { $0.key != action && $0.value == combo }?.key
    }

    func set(_ combo: KeyCombo, for action: KeyAction) { combos[action] = combo; save() }
    func reset(_ action: KeyAction) { combos[action] = action.defaultCombo; save() }
    func resetAll() { combos = Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { ($0, $0.defaultCombo) }); save() }
    var isDefault: Bool { KeyAction.allCases.allSatisfy { combo($0) == $0.defaultCombo } }

    private func save() {
        let plain = Dictionary(uniqueKeysWithValues: combos.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(plain), forKey: "keymap")
    }

    /// For /version: { "select": {"key":"v","cmd":false,...}, ... }. Read off the main thread.
    static var json: [String: Any] {
        let data = UserDefaults.standard.data(forKey: "keymap")
        let saved = data.flatMap { try? JSONDecoder().decode([String: KeyCombo].self, from: $0) } ?? [:]
        var out: [String: Any] = [:]
        for action in KeyAction.allCases {
            let c = saved[action.rawValue] ?? action.defaultCombo
            out[action.rawValue] = ["key": c.key, "cmd": c.cmd, "shift": c.shift, "alt": c.alt, "ctrl": c.ctrl, "label": c.label]
        }
        return out
    }
}
