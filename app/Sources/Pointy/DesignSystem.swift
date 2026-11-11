import AppKit
import SwiftUI

/* One place for every colour, size and motion in the app.

   Mono & lime: black, white and greys, with one acid-lime accent. Lime is too
   light to read as text on white, so in light mode text and icons use black
   (`accent`) and lime only fills (`accentFill`); in dark mode lime does both.
   The overlay draws with the same lime (extension/app.js INK), edged in black
   so it holds up on any page, and marks a selection green — keep those in step. */

/// Light and dark hex for every role.
struct Palette {
    typealias Pair = (light: UInt32, dark: UInt32)
    let background, sidebar, card, well, hairline: Pair
    let hairlineAlpha: (light: CGFloat, dark: CGFloat)
    let ink, inkSecondary, inkTertiary: Pair
    let accent, accentFill, onAccent: Pair
    let success, warning: Pair

    static let lime = Palette(
        background: (0xFAFAFA, 0x0B0B0B), sidebar: (0xF1F1F1, 0x000000), card: (0xFFFFFF, 0x161616),
        well: (0xEFEFEF, 0x202020), hairline: (0x000000, 0xFFFFFF), hairlineAlpha: (0.09, 0.09),
        ink: (0x111111, 0xF2F2F2), inkSecondary: (0x5E5E5E, 0xA3A3A3), inkTertiary: (0x9E9E9E, 0x6B6B6B),
        accent: (0x111111, 0xC8F53C), accentFill: (0xC8F53C, 0xC8F53C), onAccent: (0x111111, 0x111111),
        success: (0x2F9E44, 0xC8F53C), warning: (0xD9480F, 0xFF922B))
}

enum DS {
    static let palette = Palette.lime

    enum Colors {
        private static var p: Palette { DS.palette }
        static var background: Color { dynamic(p.background) }
        static var sidebar: Color { dynamic(p.sidebar) }
        static var card: Color { dynamic(p.card) }
        static var well: Color { dynamic(p.well) }
        static var hairline: Color { dynamic(p.hairline, alpha: p.hairlineAlpha) }

        static var ink: Color { dynamic(p.ink) }
        static var inkSecondary: Color { dynamic(p.inkSecondary) }
        static var inkTertiary: Color { dynamic(p.inkTertiary) }

        static var accent: Color { dynamic(p.accent) }
        static var accentFill: Color { dynamic(p.accentFill) }
        static var onAccent: Color { dynamic(p.onAccent) }
        static var accentSoft: Color { dynamic(p.accentFill, alpha: (0.14, 0.18)) }
        static var success: Color { dynamic(p.success) }
        static var successSoft: Color { dynamic(p.success, alpha: (0.12, 0.14)) }
        static var warning: Color { dynamic(p.warning) }

        private static func dynamic(_ pair: Palette.Pair, alpha: (light: CGFloat, dark: CGFloat) = (1, 1)) -> Color {
            dynamic(light: pair.light, dark: pair.dark, lightAlpha: alpha.light, darkAlpha: alpha.dark)
        }

        private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
            })
        }
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    enum Font {
        static let title = SwiftUI.Font.system(size: 26, weight: .semibold)
        static let heading = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 14)
        static let callout = SwiftUI.Font.system(size: 13)
        static let caption = SwiftUI.Font.system(size: 12)
        static let mono = SwiftUI.Font.system(size: 12.5, design: .monospaced)
    }

    /// UI never overshoots: critically damped, so things settle instead of bouncing.
    enum Motion {
        static let standard = Animation.spring(response: 0.32, dampingFraction: 1)
        static let slow = Animation.spring(response: 0.55, dampingFraction: 1)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Shared pieces

/// A white (or raised dark) surface with a hairline edge.
struct Card<Content: View>: View {
    var padding: CGFloat = DS.Space.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous).strokeBorder(DS.Colors.hairline))
    }
}

/// A keycap, for shortcuts: ⌃⇧P reads faster as keys than as a sentence.
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(DS.Colors.ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(DS.Colors.well, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(DS.Colors.hairline))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.Colors.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(DS.Colors.accentFill.opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: DS.Radius.small + 2, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.Colors.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(DS.Colors.well.opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: DS.Radius.small + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small + 2, style: .continuous).strokeBorder(DS.Colors.hairline))
            .contentShape(Rectangle())
    }
}
