import AppKit
import SwiftUI

/// Every key the overlay listens for, changeable. The open-on-a-page shortcut
/// belongs to the browser, so it is shown with a way to change it there.
struct ShortcutsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var keymap = Keymap.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shortcuts").font(DS.Font.title).foregroundStyle(DS.Colors.ink)
                    Text("Click a shortcut, then press the keys you want.")
                        .font(DS.Font.body).foregroundStyle(DS.Colors.inkSecondary)
                }

                Group(title: "On a page") {
                    ShortcutRow(icon: "macwindow", title: "Open pointy", last: true) {
                        HStack(spacing: DS.Space.sm) {
                            if model.shortcutMissing {
                                Text("Not set").font(DS.Font.callout).foregroundStyle(DS.Colors.warning)
                            } else {
                                HStack(spacing: 4) { ForEach(Array(model.shortcutKeys.enumerated()), id: \.offset) { Keycap(text: $0.element) } }
                            }
                            Button("Change in browser") { model.openShortcutSettings() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                }

                Group(title: "Tools") {
                    ForEach(KeyAction.allCases.filter(\.isTool)) { action in
                        ShortcutRow(icon: action.icon, title: action.title, last: action == .pass) { KeyRecorder(action: action) }
                    }
                }

                Group(title: "Actions") {
                    ForEach(KeyAction.allCases.filter { !$0.isTool }) { action in
                        ShortcutRow(icon: action.icon, title: action.title) { KeyRecorder(action: action) }
                    }
                    ShortcutRow(icon: "xmark", title: "Cancel", detail: "A shape mid-drag, the note field, start over", last: true) {
                        Keycap(text: "Esc").opacity(0.6)
                    }
                }

                HStack {
                    Spacer()
                    Button("Reset all") { withAnimation(DS.Motion.standard) { keymap.resetAll() } }
                        .buttonStyle(QuietButtonStyle()).disabled(keymap.isDefault).opacity(keymap.isDefault ? 0.5 : 1)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private struct Group<Content: View>: View {
        let title: String
        @ViewBuilder var content: Content
        var body: some View {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.inkSecondary).padding(.leading, 4)
                Card(padding: 0) { VStack(spacing: 0) { content } }
            }
        }
    }
}

private struct ShortcutRow<Control: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var last = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.inkSecondary).frame(width: 22)
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
            if !last { Rectangle().fill(DS.Colors.hairline).frame(height: 1).padding(.leading, 50) }
        }
    }
}

/// Click, press keys, done. Esc cancels; a combination another action uses is refused.
private struct KeyRecorder: View {
    let action: KeyAction
    @ObservedObject private var keymap = Keymap.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if keymap.combo(action) != action.defaultCombo && !recording {
                    Button { keymap.reset(action) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain).foregroundStyle(DS.Colors.inkTertiary).help("Back to \(action.defaultCombo.label)")
                }
                Button { recording ? stop() : start() } label: {
                    HStack(spacing: 4) {
                        if recording {
                            Text("Press keys…").font(DS.Font.callout).foregroundStyle(DS.Colors.ink).padding(.horizontal, 6)
                        } else {
                            ForEach(Array(keymap.combo(action).symbols.enumerated()), id: \.offset) { Keycap(text: $0.element) }
                        }
                    }
                    .padding(4)
                    .frame(minWidth: 64, minHeight: 30)
                    .background(recording ? DS.Colors.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(recording ? DS.Colors.accentFill : DS.Colors.hairline, lineWidth: recording ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click, then press the new keys")
            }
            if let message { Text(message).font(DS.Font.caption).foregroundStyle(DS.Colors.warning) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        message = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }                 // Esc: cancel
            guard let combo = KeyCombo(event: event) else { return nil }
            if let other = keymap.conflict(combo, for: action) {
                message = "\(combo.label) already does \(other.title)"
            } else {
                withAnimation(DS.Motion.standard) { keymap.set(combo, for: action) }
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
