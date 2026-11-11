import AppKit
import SwiftUI

/// The reward: a burst of the overlay's own marks — rectangles, circles, arrows
/// and selection dots, in its orange and green — thrown up from the top and
/// falling away. Physics, so things arc and fade; nothing springs back.
struct MarkBurst: View {
    let trigger: Int
    @State private var start: Date?

    private struct Piece {
        let kind: Int, x: Double, vx: Double, vy: Double, spin: Double, size: Double, green: Bool
    }

    private let pieces: [Piece] = {
        var rng = SystemRandomNumberGenerator()
        return (0..<34).map { i in
            Piece(kind: i % 4,
                  x: Double.random(in: 0.2...0.8, using: &rng),
                  vx: Double.random(in: -0.22...0.22, using: &rng),
                  vy: Double.random(in: 0.55...1.0, using: &rng),
                  spin: Double.random(in: -2.5...2.5, using: &rng),
                  size: Double.random(in: 12...22, using: &rng),
                  green: i % 3 == 0)
        }
    }()

    private let duration = 2.4

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { timeline in
            Canvas { ctx, size in
                guard let start else { return }
                let t = timeline.date.timeIntervalSince(start)
                guard t < duration else { return }
                for p in pieces {
                    // Launched upward from just below the top edge, then gravity.
                    let x = (p.x + p.vx * t) * size.width
                    let y = size.height * (0.32 - p.vy * t + 0.9 * t * t)
                    let fade = max(0, 1 - pow(t / duration, 2))
                    var c = ctx
                    c.opacity = fade
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.spin * t))
                    let color = p.green ? DS.Colors.success : DS.Colors.accentFill
                    let s = p.size
                    let style = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                    switch p.kind {
                    case 0: c.stroke(Path(roundedRect: CGRect(x: -s / 2, y: -s / 3, width: s, height: s * 0.66), cornerRadius: 3), with: .color(color), style: style)
                    case 1: c.stroke(Path(ellipseIn: CGRect(x: -s / 2, y: -s / 2, width: s, height: s)), with: .color(color), style: style)
                    case 2:
                        var a = Path()
                        a.move(to: CGPoint(x: -s / 2, y: s / 2)); a.addLine(to: CGPoint(x: s / 2, y: -s / 2))
                        a.move(to: CGPoint(x: s / 2 - s * 0.38, y: -s / 2)); a.addLine(to: CGPoint(x: s / 2, y: -s / 2)); a.addLine(to: CGPoint(x: s / 2, y: -s / 2 + s * 0.38))
                        c.stroke(a, with: .color(color), style: style)
                    default: c.fill(Path(ellipseIn: CGRect(x: -s / 4, y: -s / 4, width: s / 2, height: s / 2)), with: .color(color))
                    }
                }
            }
        }
        .onChange(of: trigger) { _, _ in
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { start = nil }
        }
    }
}

/// A screenshot from a session folder, loaded off the main thread.
struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        // The image goes in an overlay so a filled picture can never size the cell
        // — as a ZStack child it pushed the whole Sessions layout off the window.
        Rectangle()
            .fill(DS.Colors.well)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small + 2, style: .continuous).strokeBorder(DS.Colors.hairline))
        .task(id: url) {
            let loaded = await Task.detached { NSImage(contentsOf: url) }.value
            image = loaded
        }
    }
}

/// Copies, then says so for a moment.
struct CopyButton: View {
    var title = "Copy brief"
    var primary = true
    let text: () -> String
    @State private var copied = false

    var body: some View {
        let label = Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
            .contentTransition(.symbolEffect(.replace))
        let action = {
            Clipboard.set(text())
            withAnimation(DS.Motion.standard) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(DS.Motion.standard) { copied = false } }
        }
        if primary { Button(action: action) { label }.buttonStyle(PrimaryButtonStyle()) }
        else { Button(action: action) { label }.buttonStyle(QuietButtonStyle()) }
    }
}
