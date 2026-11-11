import AppKit
import SwiftUI

/// What Settings changes. Stored in UserDefaults; read from any thread through `current`.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// Where speech becomes text. The browser engine is Web Speech inside the
    /// extension (audio goes to the browser maker's servers); the other two run
    /// on this Mac and need macOS 26.
    enum Engine: String, CaseIterable, Identifiable {
        case appleSpeech = "apple-speech"
        case appleDictation = "apple-dictation"
        case browser
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appleSpeech: return "Apple Speech"
            case .appleDictation: return "Apple Dictation"
            case .browser: return "Browser speech"
            }
        }
        var detail: String {
            switch self {
            case .appleSpeech: return "Newest on-device model. Best for long, natural talking."
            case .appleDictation: return "The model behind macOS dictation. Also on device."
            case .browser: return "Your browser's speech service. Audio leaves this Mac."
            }
        }
        var onDevice: Bool { self != .browser }
    }

    static let keepOptions = [10, 25, 50, 100]
    /// Hours. The folder is the system temp folder, which macOS also clears after a
    /// few days unused, so nothing longer than three days is offered.
    static let ageOptions: [Double] = [1, 6, 24, 72]

    @AppStorage("keepCount") var keepCount = 25
    @AppStorage("maxAgeHours") var maxAgeHours: Double = 24
    @AppStorage("appearance") var appearanceRaw = Appearance.system.rawValue { didSet { applyAppearance() } }
    @AppStorage("engine") var engineRaw = Preferences.defaultEngine.rawValue
    @AppStorage("speechLocale") var speechLocale = ""
    /// A CoreAudio device UID; empty means the system's default input.
    @AppStorage("inputDeviceUID") var inputDeviceUID = ""
    @AppStorage("playSound") var playSound = true

    var appearance: Appearance { Appearance(rawValue: appearanceRaw) ?? .system }
    var engine: Engine {
        let e = Engine(rawValue: engineRaw) ?? .browser
        return Transcription.isAvailable(e) ? e : .browser
    }

    /// Best on-device engine this Mac has. SpeechTranscriber needs Apple silicon;
    /// on an Intel Mac on macOS 26, Dictation is still there.
    static var defaultEngine: Engine {
        [.appleSpeech, .appleDictation].first { Transcription.isAvailable($0) } ?? .browser
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static func ageLabel(_ hours: Double) -> String {
        hours < 24 ? "\(Int(hours)) hour\(hours == 1 ? "" : "s")" : "\(Int(hours / 24)) day\(hours == 24 ? "" : "s")"
    }
}
