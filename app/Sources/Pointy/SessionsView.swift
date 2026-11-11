import SwiftUI

/// Every kept session, newest first, so a brief that fell off the clipboard can
/// be copied again.
struct SessionsView: View {
    @EnvironmentObject var library: SessionLibrary
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var model: AppModel
    @State private var selection: SessionSummary.ID?

    private var selected: SessionSummary? {
        library.sessions.first { $0.id == selection } ?? library.sessions.first
    }

    var body: some View {
        if library.sessions.isEmpty {
            empty
        } else {
            HStack(spacing: 0) {
                list.frame(width: 290)
                Rectangle().fill(DS.Colors.hairline).frame(width: 1)
                if let s = selected { SessionDetail(session: s).id(s.id) }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sessions").font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.Colors.ink)
                Text("Kept for \(Preferences.ageLabel(prefs.maxAgeHours)), up to \(prefs.keepCount)")
                    .font(DS.Font.caption).foregroundStyle(DS.Colors.inkTertiary)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, 48)
            .padding(.bottom, DS.Space.md)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Colors.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                        ForEach(group.items) { s in
                            SessionRow(session: s, selected: s.id == selected?.id)
                                .onTapGesture { selection = s.id }
                        }
                    }
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.bottom, DS.Space.lg)
            }
        }
    }

    private var groups: [(title: String, items: [SessionSummary])] {
        let cal = Calendar.current
        var out: [(String, [SessionSummary])] = []
        for s in library.sessions {
            let title = cal.isDateInToday(s.date) ? "Today" : cal.isDateInYesterday(s.date) ? "Yesterday"
                : s.date.formatted(.dateTime.weekday(.wide).day().month())
            if out.last?.0 == title { out[out.count - 1].1.append(s) } else { out.append((title, [s])) }
        }
        return out.map { (title: $0.0, items: $0.1) }
    }

    private var empty: some View {
        VStack(spacing: DS.Space.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).strokeBorder(DS.Colors.accent, style: StrokeStyle(lineWidth: 2.5, dash: [6, 5]))
                    .frame(width: 74, height: 52)
                Image(systemName: "scribble").font(.system(size: 22, weight: .medium)).foregroundStyle(DS.Colors.accent)
            }
            .padding(.bottom, DS.Space.sm)
            Text("No sessions yet").font(DS.Font.heading).foregroundStyle(DS.Colors.ink)
            HStack(spacing: 4) {
                ForEach(model.shortcutKeys, id: \.self) { Keycap(text: $0) }
                Text("on any page, draw, talk,").foregroundStyle(DS.Colors.inkSecondary)
                ForEach(Array(Keymap.shared.combo(.done).symbols.enumerated()), id: \.offset) { Keycap(text: $0.element) }
            }
            .font(DS.Font.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            if let crop = session.crops.first {
                Thumbnail(url: crop).frame(width: 46, height: 34)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(DS.Colors.well).frame(width: 46, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.host).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.ink).lineLimit(1)
                    Spacer()
                    Text(session.date.formatted(date: .omitted, time: .shortened))
                        .font(DS.Font.caption).foregroundStyle(DS.Colors.inkTertiary)
                }
                Text(session.said.isEmpty ? "\(session.marks) mark\(session.marks == 1 ? "" : "s")" : session.said)
                    .font(DS.Font.caption).foregroundStyle(DS.Colors.inkSecondary).lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
            .fill(selected ? DS.Colors.accentSoft : hover ? DS.Colors.hairline.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

private struct SessionDetail: View {
    let session: SessionSummary
    @EnvironmentObject var library: SessionLibrary
    @State private var confirmDelete = false
    @State private var showBrief = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                // Title, then actions on their own line: beside the title they
                // squeezed "Copy brief" to "C" at the window's normal width.
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.host).font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.Colors.ink)
                        Text(meta).font(DS.Font.callout).foregroundStyle(DS.Colors.inkSecondary)
                    }
                    HStack(spacing: 6) {
                        CopyButton { SessionStore.payload(dir: session.dir, brief: session.brief) }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([session.briefURL]) } label: {
                            Image(systemName: "folder")
                        }.buttonStyle(QuietButtonStyle()).help("Show in Finder")
                        Button { confirmDelete = true } label: { Image(systemName: "trash") }
                            .buttonStyle(QuietButtonStyle()).help("Delete")
                    }
                    .fixedSize()
                }

                if !session.said.isEmpty {
                    Text("“\(session.said)”")
                        .font(.system(size: 15)).foregroundStyle(DS.Colors.ink).lineSpacing(3)
                        .textSelection(.enabled)
                }

                if !session.crops.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DS.Space.md)], spacing: DS.Space.md) {
                        ForEach(session.crops, id: \.self) { url in
                            Thumbnail(url: url).aspectRatio(1.45, contentMode: .fit)
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Button { withAnimation(DS.Motion.standard) { showBrief.toggle() } } label: {
                        Label(showBrief ? "Hide brief" : "Show brief", systemImage: "doc.text")
                    }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.accent)
                    if showBrief {
                        Text(session.brief)
                            .font(DS.Font.mono).foregroundStyle(DS.Colors.ink)
                            .textSelection(.enabled)
                            .padding(DS.Space.lg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Colors.well, in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)
            .padding(.bottom, 32)
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { library.delete(session) }
        } message: {
            Text("Its brief and screenshots are removed from this Mac.")
        }
    }

    private var meta: String {
        var parts = [session.date.formatted(date: .abbreviated, time: .shortened),
                     "\(session.marks) mark\(session.marks == 1 ? "" : "s")"]
        if session.duration > 0 {
            let s = Int(session.duration)
            parts.append(s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s")
        }
        if session.pages.count > 1 { parts.append("\(session.pages.count) pages") }
        return parts.joined(separator: " · ")
    }
}
