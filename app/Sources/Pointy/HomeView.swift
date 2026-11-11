import SwiftUI

/// Home: the five things to do once, then — when they are done — a small
/// celebration and a home that is about your notes instead of about setup.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: SessionLibrary
    @EnvironmentObject var prefs: Preferences
    @ObservedObject private var keymap = Keymap.shared
    @State private var browser: Browser? = Browser.installed.first
    @State private var installOpened = false
    @State private var burst = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                header
                if model.setupDone { doneCard; stats; latest } else { checklist }
                shortcuts
            }
            .padding(.horizontal, 40)
            .padding(.top, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay { MarkBurst(trigger: burst).allowsHitTesting(false) }
        .onAppear(perform: celebrateIfDue)
        .onChange(of: model.setupDone) { _, _ in celebrateIfDue() }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting).font(DS.Font.title).foregroundStyle(DS.Colors.ink)
            Text(model.setupDone ? "Draw on any page, talk, and the brief is on your clipboard."
                                 : "A few things to do once, and you're drawing.")
                .font(DS.Font.body).foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Up late" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }

    // MARK: checklist

    private var steps: [Bool] { model.setupSteps }

    private var checklist: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.md) {
                    ProgressRing(done: steps.filter { $0 }.count, total: steps.count)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get set up").font(DS.Font.heading).foregroundStyle(DS.Colors.ink)
                        Text("\(steps.filter { $0 }.count) of \(steps.count) done")
                            .font(DS.Font.callout).foregroundStyle(DS.Colors.inkSecondary)
                    }
                    Spacer()
                }
                .padding(DS.Space.lg)

                Divider().overlay(DS.Colors.hairline)

                StepRow(done: model.serverOK, failed: !model.serverOK && model.serverStatus != "Starting…",
                        icon: "antenna.radiowaves.left.and.right", title: "Notes server is running",
                        detail: model.serverStatus)

                StepRow(done: model.extensionConnected && !model.shortcutMissing, failed: model.shortcutMissing, icon: "puzzlepiece.extension",
                        title: "Add the browser extension",
                        detail: model.shortcutMissing ? "Connected, but your browser gave it no shortcut. Set one, or click its toolbar icon."
                              : model.extensionConnected ? "Connected, v\(model.extensionVersion ?? "")." : "So you can draw on pages in \(Browser.installed.map(\.name).joined(separator: ", ").ifEmpty("your browser")).") {
                    if !model.extensionConnected && !Browser.installed.isEmpty { extensionAction }
                    if model.shortcutMissing {
                        Button("Set shortcut") { model.openShortcutSettings() }.buttonStyle(PrimaryButtonStyle())
                    }
                } below: {
                    if installOpened && !model.extensionConnected { LoadUnpackedSteps() }
                }

                StepRow(done: model.micOK, failed: model.micStatus == "denied" || model.micBlocked, icon: "mic",
                        title: "Turn on the microphone",
                        detail: model.micBlocked ? "No sound came from that microphone. Pick another one in Settings."
                              : model.micStatus == "denied" ? "It was turned off. Switch Pointy on in System Settings."
                              : "So what you say becomes part of the brief, transcribed on this Mac.", accessory: {
                    if !model.micOK {
                        Button(model.micBlocked ? "Choose mic" : model.micStatus == "undetermined" ? "Allow" : "Open Settings") { model.allowMicrophone() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                })

                StepRow(done: model.commandInstalled, icon: "terminal", title: "Add /ui to Claude Code",
                        detail: "Reads the latest brief and its screenshots, in any project.", accessory: {
                    if !model.commandInstalled {
                        Button("Add") { withAnimation(DS.Motion.standard) { model.installCommand() } }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                })

                StepRow(done: model.firstNoteDone, icon: "scribble.variable", title: "Make your first note",
                        detail: "Open any page, then draw and talk.", accessory: {
                    if !model.firstNoteDone {
                        HStack(spacing: 4) { ForEach(model.shortcutKeys, id: \.self) { Keycap(text: $0) } }
                    }
                })

                StepRow(done: model.opensAtLogin, icon: "power", title: "Start with your Mac",
                        detail: "So it is always ready when you are.", last: true, accessory: {
                    if !model.opensAtLogin {
                        Button("Turn on") { withAnimation(DS.Motion.standard) { model.setOpensAtLogin(true) } }
                            .buttonStyle(QuietButtonStyle())
                    }
                })
            }
        }
    }

    @ViewBuilder private var extensionAction: some View {
        HStack(spacing: 6) {
            if Browser.installed.count > 1 {
                Picker("", selection: $browser) {
                    ForEach(Browser.installed) { Text($0.name).tag(Optional($0)) }
                }
                .labelsHidden().fixedSize()
            }
            Button(installOpened ? "Open again" : "Install") {
                if let browser { model.installer.install(in: browser) }
                withAnimation(DS.Motion.standard) { installOpened = true }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: done

    private var doneCard: some View {
        Card {
            HStack(spacing: DS.Space.lg) {
                ZStack {
                    Circle().fill(DS.Colors.successSoft).frame(width: 52, height: 52)
                    Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(DS.Colors.success)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("You're all set").font(DS.Font.heading).foregroundStyle(DS.Colors.ink)
                    Text("Everything's connected. Go mark something up.")
                        .font(DS.Font.callout).foregroundStyle(DS.Colors.inkSecondary)
                }
                Spacer()
                Button { burst += 1 } label: { Image(systemName: "sparkles") }
                    .buttonStyle(QuietButtonStyle()).help("Again!")
            }
        }
    }

    private var stats: some View {
        let today = library.sessions.filter { Calendar.current.isDateInToday($0.date) }
        return HStack(spacing: DS.Space.md) {
            Stat(value: "\(today.count)", label: today.count == 1 ? "note today" : "notes today")
            Stat(value: "\(library.sessions.reduce(0) { $0 + $1.marks })", label: "marks kept")
            Stat(value: "\(library.sessions.count)", label: library.sessions.count == 1 ? "session kept" : "sessions kept")
        }
    }

    @ViewBuilder private var latest: some View {
        if let s = library.sessions.first {
            Card {
                HStack(spacing: DS.Space.md) {
                    if let crop = s.crops.first { Thumbnail(url: crop).frame(width: 84, height: 56) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Latest · \(s.host)").font(DS.Font.heading).foregroundStyle(DS.Colors.ink)
                        Text(s.said.isEmpty ? "\(s.marks) marks, no speech" : "“\(s.said)”")
                            .font(DS.Font.callout).foregroundStyle(DS.Colors.inkSecondary).lineLimit(2)
                    }
                    Spacer()
                    CopyButton { SessionStore.payload(dir: s.dir, brief: s.brief) }
                }
            }
        }
    }

    private var shortcuts: some View {
        HStack(spacing: DS.Space.lg) {
            Shortcut(keys: model.shortcutKeys, label: "open")
            Shortcut(keys: [KeyAction.select, .rect, .oval, .arrow].map { keymap.combo($0).label }, label: "tools")
            Shortcut(keys: keymap.combo(.done).symbols, label: "done")
            Shortcut(keys: ["/ui"], label: "in Claude Code")
        }
        .padding(.top, DS.Space.sm)
    }

    private func celebrateIfDue() {
        guard model.setupDone, !model.celebrated else { return }
        model.celebrated = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            burst += 1
            if prefs.playSound { NSSound(named: "Hero")?.play() }
        }
    }
}

// MARK: - pieces

private struct StepRow<Accessory: View, Below: View>: View {
    let done: Bool
    var failed = false
    let icon: String
    let title: String
    let detail: String
    var last = false
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var below: Below

    init(done: Bool, failed: Bool = false, icon: String, title: String, detail: String, last: Bool = false,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder below: () -> Below = { EmptyView() }) {
        self.done = done; self.failed = failed; self.icon = icon; self.title = title; self.detail = detail
        self.last = last; self.accessory = accessory(); self.below = below()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                ZStack {
                    Circle().fill(done ? DS.Colors.successSoft : failed ? DS.Colors.warning.opacity(0.12) : DS.Colors.well)
                        .frame(width: 34, height: 34)
                    Image(systemName: done ? "checkmark" : failed ? "exclamationmark" : icon)
                        .font(.system(size: done ? 14 : 13, weight: done ? .bold : .medium))
                        .foregroundStyle(done ? DS.Colors.success : failed ? DS.Colors.warning : DS.Colors.inkSecondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(done ? DS.Colors.inkSecondary : DS.Colors.ink)
                    Text(detail).font(DS.Font.callout).foregroundStyle(DS.Colors.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.md)
                accessory
            }
            below.padding(.leading, 46)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(DS.Colors.hairline).frame(height: 1).padding(.leading, 62) }
        }
        .animation(DS.Motion.standard, value: done)
    }
}

/// The four moves in Chrome/Edge, shown once Install has opened the page.
private struct LoadUnpackedSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            line(1) { Text("Turn on **Developer mode**") }
            line(2) { Text("Click **Load unpacked**") }
            line(3) { HStack(spacing: 4) { Keycap(text: "⌘"); Keycap(text: "⇧"); Keycap(text: "G"); Text("then"); Keycap(text: "⌘"); Keycap(text: "V"); Text("— the path is copied") } }
            line(4) { HStack(spacing: 4) { Keycap(text: "Return"); Text("and **Select**") } }
        }
        .font(DS.Font.callout)
        .foregroundStyle(DS.Colors.inkSecondary)
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.well, in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        .transition(.opacity)
    }

    private func line<C: View>(_ n: Int, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(DS.Colors.onAccent)
                .frame(width: 18, height: 18).background(DS.Colors.accentFill, in: Circle())
            content()
        }
    }
}

private struct ProgressRing: View {
    let done: Int
    let total: Int
    var body: some View {
        ZStack {
            Circle().stroke(DS.Colors.well, lineWidth: 4)
            Circle().trim(from: 0, to: CGFloat(done) / CGFloat(max(total, 1)))
                .stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DS.Motion.slow, value: done)
        }
        .frame(width: 34, height: 34)
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(DS.Colors.ink)
                    .contentTransition(.numericText())
                Text(label).font(DS.Font.callout).foregroundStyle(DS.Colors.inkSecondary)
            }
        }
    }
}

private struct Shortcut: View {
    let keys: [String]
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { Keycap(text: $0.element) }
            Text(label).font(DS.Font.caption).foregroundStyle(DS.Colors.inkTertiary).padding(.leading, 2)
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
