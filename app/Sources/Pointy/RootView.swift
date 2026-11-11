import SwiftUI

/// Sidebar on the left — Home and Sessions at the top, Settings pinned to the
/// bottom — and the selected page on the right.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: SessionLibrary
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .background(DS.Colors.sidebar)
            Rectangle().fill(DS.Colors.hairline).frame(width: 1)
            Group {
                switch model.tab {
                case .home: HomeView()
                case .sessions: SessionsView()
                case .shortcuts: ShortcutsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Colors.background)
            .transition(.opacity)
        }
        .animation(DS.Motion.standard, value: model.tab)
        .ignoresSafeArea()
        .tint(DS.Colors.accent)
        .preferredColorScheme(prefs.appearance == .light ? .light : prefs.appearance == .dark ? .dark : nil)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AppMark(size: 28)
                Text("Pointy").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Colors.ink)
            }
            .padding(.horizontal, 10)
            .padding(.top, 52)       // clear of the traffic lights
            .padding(.bottom, 18)

            SidebarItem(icon: "house", title: "Home", selected: model.tab == .home,
                        badge: model.setupDone ? nil : "\(setupLeft)") { model.tab = .home }
            SidebarItem(icon: "clock", title: "Sessions", selected: model.tab == .sessions,
                        badge: library.sessions.isEmpty ? nil : "\(library.sessions.count)", badgeQuiet: true) { model.tab = .sessions }
            SidebarItem(icon: "keyboard", title: "Shortcuts", selected: model.tab == .shortcuts) { model.tab = .shortcuts }

            Spacer()

            SidebarItem(icon: "gearshape", title: "Settings", selected: model.tab == .settings) { model.tab = .settings }
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
    }

    private var setupLeft: Int {
        model.setupSteps.filter { !$0 }.count
    }
}

private struct SidebarItem: View {
    let icon: String
    let title: String
    let selected: Bool
    var badge: String? = nil
    var badgeQuiet = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? icon + ".fill" : icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? DS.Colors.accent : DS.Colors.inkSecondary)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DS.Colors.ink : DS.Colors.inkSecondary)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(badgeQuiet ? DS.Colors.inkTertiary : DS.Colors.onAccent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(badgeQuiet ? Color.clear : DS.Colors.accentFill, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.medium - 2, style: .continuous)
                    .fill(selected ? DS.Colors.accentSoft : hover ? DS.Colors.hairline.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The app's mark is pointy himself: a lime rounded square with a thick black
/// edge, two dot eyes and a small smile — the same face as the app icon.
struct AppMark: View {
    var size: CGFloat = 28
    private let ink = Color(nsColor: NSColor(hex: 0x111111))
    private let lime = Color(nsColor: NSColor(hex: 0xC8F53C))

    var body: some View {
        let line = max(1.5, size * 0.07)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(lime)
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(ink, lineWidth: line)
            HStack(spacing: size * 0.2) {
                Circle().fill(ink).frame(width: size * 0.13, height: size * 0.13)
                Circle().fill(ink).frame(width: size * 0.13, height: size * 0.13)
            }
            .offset(y: -size * 0.07)
            Smile().stroke(ink, style: StrokeStyle(lineWidth: line * 0.9, lineCap: .round))
                .frame(width: size * 0.24, height: size * 0.1)
                .offset(y: size * 0.15)
        }
        .frame(width: size, height: size)
    }

    private struct Smile: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 2))
            return p
        }
    }
}
