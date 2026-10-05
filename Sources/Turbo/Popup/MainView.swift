import AppKit
import SwiftUI
import TurboCore

/// Where the two-pane view lives: grown out of the notch, or in its own window.
enum MainHost {
    case popup
    case window
}

/// Turbo's big view, HeyClicky style: sessions on the left, the one you picked (or settings)
/// on the right. The same view fills the notch pop-up and the detached window.
struct MainView: View {
    @EnvironmentObject private var model: AppModel
    let host: MainHost
    @State private var query = ""
    @State private var sidebarHidden = false

    var body: some View {
        HStack(spacing: 0) {
            if model.popupPage != .welcome && !sidebarHidden {
                MainSidebar(host: host, query: $query, sidebarHidden: $sidebarHidden)
                    .frame(width: 290)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            }
            MainDetailPane(host: host, sidebarHidden: $sidebarHidden)
        }
        .background(DS.Palette.base)
        .animation(DS.Motion.base, value: sidebarHidden)
        .animation(DS.Motion.base, value: model.popupPage)
    }
}

// MARK: Sidebar

private struct MainSidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    let host: MainHost
    @Binding var query: String
    @Binding var sidebarHidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Leaves room for the window's traffic lights.
            if host == .window { Color.clear.frame(height: 22) }
            HStack(spacing: 8) {
                AppIconView(size: 24)
                Text("Turbo").font(DSFont.display(17)).foregroundStyle(DS.Palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                RoundIconButton(symbol: "sidebar.left", help: "Hide sidebar", size: 28) { sidebarHidden = true }
                SearchField(text: $query)
                NewSessionMenu()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let sessions = filtered
                        if sessions.isEmpty {
                            Text(query.isEmpty ? "No sessions yet." : "No sessions match.")
                                .font(DSFont.sans(12.5, .medium))
                                .foregroundStyle(DS.Palette.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            SidebarRow(session: session, now: context.date, divider: index > 0 && sessions[index - 1].id != model.selectedSessionID && session.id != model.selectedSessionID)
                        }
                    }
                    .padding(.horizontal, 8)
                    .animation(DS.Motion.base, value: filtered.map(\.id))
                }
            }

            Spacer(minLength: 0)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 12)

            UserRow()
                .padding(.horizontal, 14)
                .padding(.top, 10)
                // Clear of the pop-up's rounded bottom corner.
                .padding(.bottom, 16)
        }
        .background(DS.Palette.rail)
    }

    private var filtered: [AgentSession] {
        let all = model.board.all
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { session in
            [session.projectName, session.repoName ?? "", session.lastPrompt ?? "", session.agent.displayName]
                .contains { $0.lowercased().contains(q) }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Palette.textTertiary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(DSFont.sans(13, .medium))
                .foregroundStyle(DS.Palette.textPrimary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

/// "+": start a new session in the place you'd usually start one.
private struct NewSessionMenu: View {
    var body: some View {
        Menu {
            Button("New Claude Code Session") { NSWorkspace.shared.open(URL(string: "https://claude.ai/code")!) }
            Button("New Codex Task") { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Start a new session")
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let session: AgentSession
    let now: Date
    let divider: Bool
    @State private var hovering = false

    var body: some View {
        let selected = model.selectedSessionID == session.id
        ChatRow(session: session, now: now, compact: true, showsAction: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.1) : Color.white.opacity(hovering ? 0.05 : 0))
            )
            .overlay(alignment: .top) {
                if divider && !hovering {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 52).padding(.trailing, 8)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { model.open(session) }
            .onTapGesture {
                model.selectedSessionID = session.id
                model.popupPage = .home
                model.markSeen(session)
            }
            .contextMenu {
                if model.canOpen(session) { Button("Open") { model.open(session) } }
                if model.stopMethod(for: session) != nil { Button("Stop") { model.stop(session) } }
                if !session.phase.isActive { Button("Dismiss") { model.dismiss(session) } }
            }
            .animation(DS.Motion.fast, value: hovering)
    }
}

/// You, at the bottom of the sidebar: like a chat app's account row.
private struct UserRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(Greeting.initials)
                .font(DSFont.sans(12, .heavy))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(DS.Palette.brand))
            VStack(alignment: .leading, spacing: 1) {
                Text(Greeting.fullName).font(DSFont.sans(13, .bold)).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                if let usage = model.usage {
                    UsageMeter(usage: usage)
                } else {
                    Text(summary).font(DSFont.sans(11.5, .medium)).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            RoundIconButton(symbol: model.isQuiet ? "bell.slash.fill" : "bell", help: model.isQuiet ? "Quiet. Click to turn alerts back on" : "Quiet for 1 hour", size: 28) {
                model.setQuiet(for: model.isQuiet ? nil : 3600)
            }
            RoundIconButton(symbol: "gearshape.fill", help: "Settings", size: 28) { model.popupPage = .settings }
        }
    }

    private var summary: String {
        let board = model.board
        var parts: [String] = []
        if !board.needsYou.isEmpty { parts.append("\(board.needsYou.count) need you") }
        if !board.cooking.isEmpty { parts.append("\(board.cooking.count) cooking") }
        if parts.isEmpty { parts.append(model.isQuiet ? "Quiet" : "All caught up") }
        return parts.joined(separator: " · ")
    }
}

enum Greeting {
    static var fullName: String {
        let name = NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }

    static var firstName: String {
        fullName.split(separator: " ").first.map(String.init) ?? fullName
    }

    static var initials: String {
        let letters = fullName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "T" : String(letters).uppercased()
    }

    static func line(now: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        let part = hour < 5 ? "Up late" : hour < 12 ? "Morning" : hour < 17 ? "Afternoon" : "Evening"
        return "\(part), \(firstName)."
    }
}

// MARK: Detail pane

private struct MainDetailPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    let host: MainHost
    @Binding var sidebarHidden: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if model.popupPage == .welcome {
                WelcomeFlow()
            } else {
                VStack(spacing: DS.Space.s) {
                    if let error = model.serverError {
                        Callout(symbol: "exclamationmark.triangle.fill", text: error, tone: .bad)
                    }
                    UpdateBanner(updater: model.updater)
                    if !Integrations.isClaudeInstalled && !prefs.cloudEnabled && model.popupPage == .home {
                        SetupBanner()
                    }
                }
                .padding(.horizontal, DS.Space.xl)

                Group {
                    if model.popupPage == .settings {
                        ScrollView {
                            SettingsPage()
                                .frame(maxWidth: 620)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, DS.Space.xl)
                                .padding(.bottom, DS.Space.xl)
                        }
                    } else if let session = selected {
                        SessionPane(session: session)
                            .id(session.id)
                    } else {
                        HomeEmptyState()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .background(DS.Palette.base)
    }

    private var selected: AgentSession? {
        guard let id = model.selectedSessionID else { return nil }
        return model.sessions.first { $0.id == id }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            if sidebarHidden && model.popupPage != .welcome {
                RoundIconButton(symbol: "sidebar.left", help: "Show sidebar", size: 28) { sidebarHidden = false }
            }
            if model.popupPage == .settings {
                RoundIconButton(symbol: "chevron.left", help: "Back", size: 28) { model.popupPage = .home }
                Text("Settings").font(DSFont.sans(15, .heavy)).foregroundStyle(DS.Palette.textPrimary)
            }
            Spacer()
            if model.popupPage != .welcome {
                RoundIconButton(symbol: "sparkles", help: "Visualizer", size: 28) { model.openVisualizer() }
            }
            switch host {
            case .popup:
                RoundIconButton(symbol: "macwindow.on.rectangle", help: "Open in a window", size: 28) { model.detachToWindow() }
                RoundIconButton(symbol: "xmark", help: "Close (Esc)", size: 28) { model.closePopup() }
            case .window:
                RoundIconButton(symbol: "rectangle.topthird.inset.filled", help: "Back to the notch", size: 28) { model.attachToNotch() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, host == .window ? 10 : 12)
        .frame(height: 50)
    }
}

/// Nothing picked: the mascot, the shortcut, and a hello. Mirrors HeyClicky's empty chat.
private struct HomeEmptyState: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                AppIconView(size: 112)
                    .shadow(color: DS.Palette.brand.opacity(0.55), radius: 28)
                    .offset(y: reduceMotion ? 0 : CGFloat(sin(t * 1.6)) * 4)
            }
            .frame(height: 124)

            // The pill sits on the mascot like HeyClicky's "Hi, how can I help".
            HStack(spacing: 8) {
                Image(systemName: "keyboard").font(.system(size: 12, weight: .semibold))
                Text(model.hotKeyAvailable ? "⌃⌥Space shows what needs you" : "Pick a session on the left")
                    .font(DSFont.sans(13, .semibold))
            }
            .foregroundStyle(DS.Palette.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(DS.Palette.brand.opacity(0.22)))
            .overlay(Capsule().strokeBorder(DS.Palette.brand.opacity(0.7), lineWidth: 1.5))
            .padding(.top, -8)

            Text(Greeting.line())
                .font(DSFont.display(24))
                .foregroundStyle(DS.Palette.textPrimary)
                .padding(.top, 22)
            Text(hint)
                .font(DSFont.sans(13.5, .medium))
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 40)

            if model.sessions.isEmpty {
                Button("Play a Busy Day") {
                    model.closePopup()
                    model.simulateBusyDay()
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 18)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var hint: String {
        let board = model.board
        if !board.needsYou.isEmpty {
            return "\(board.needsYou.count) session\(board.needsYou.count == 1 ? " needs" : "s need") you. Pick one on the left."
        }
        if !board.cooking.isEmpty {
            return "\(board.cooking.count) cooking. Turbo taps you in the notch the moment one's done."
        }
        return "Start a session anywhere. Turbo shows it here and in the notch."
    }
}

/// One session as a conversation, iMessage style: what you asked on the right in Blurple,
/// Claude's replies on the left, each step as a quiet line between them, and a typing bubble
/// while it works. Actions live where the reply box would be.
private struct SessionPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    let session: AgentSession
    /// For local sessions, the whole conversation read from Claude's transcript.
    @State private var transcriptThread: [ThreadItem] = []

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(session: session)
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if items.isEmpty || (session.agent.isCloud && !prefs.cloudShareTitles) {
                            Text(session.agent.isCloud && !prefs.cloudShareTitles
                                 ? "Turn on Show Cloud Conversations in Settings to see prompts and replies here. For now, you'll see each step."
                                 : "The conversation shows up here as it happens.")
                                .font(DSFont.sans(12, .medium))
                                .foregroundStyle(DS.Palette.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                                .padding(.vertical, 10)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if showsTime(at: index) {
                                Text(timeLabel(item.date))
                                    .font(DSFont.sans(11, .semibold))
                                    .foregroundStyle(DS.Palette.textTertiary)
                                    .padding(.top, 10)
                                    .padding(.bottom, 2)
                            }
                            ThreadRow(item: item, session: session, lastInRun: isLastInRun(index))
                        }
                        // Replies waiting for the turn to end, shown as sent-but-pending.
                        ForEach(Array((model.queuedReplies[session.id] ?? []).enumerated()), id: \.offset) { _, text in
                            VStack(alignment: .trailing, spacing: 3) {
                                HStack {
                                    Spacer(minLength: 80)
                                    Bubble(text: text, fill: DS.Palette.brand.opacity(0.55), foreground: .white, mine: true, tail: true)
                                }
                                Button("Queued. Claude reads it when this step's done. Cancel") { model.cancelQueuedReplies(for: session) }
                                    .buttonStyle(.plain)
                                    .font(DSFont.sans(10.5, .medium))
                                    .foregroundStyle(DS.Palette.textTertiary)
                            }
                        }
                        if session.phase == .cooking {
                            TypingBubble(caption: session.activityDetail ?? session.activity)
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.vertical, DS.Space.m)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: items.count) { _ in
                    withAnimation(DS.Motion.base) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            ComposerBar(session: session)
        }
        // Re-read when anything changes, including a final reply that lands after the turn ends.
        .task(id: "\(session.lastActivityAt.timeIntervalSince1970)|\(session.summary ?? "")|\(session.thread.count)") {
            guard let path = session.transcriptPath else { return }
            let thread = await Task.detached(priority: .utility) { ClaudeTranscript.thread(atPath: path) }.value
            guard !Task.isCancelled else { return }
            transcriptThread = thread
        }
    }

    /// The transcript when Turbo can read one (it has everything); otherwise what the hooks reported.
    private var items: [ThreadItem] {
        var base = transcriptThread.isEmpty ? session.thread : transcriptThread
        // Waiting and done markers come from Turbo itself, not the transcript.
        if !transcriptThread.isEmpty {
            var next = (base.map(\.id).max() ?? 0) + 1
            if case let .needsInput(message) = session.phase {
                base.append(ThreadItem(id: next, kind: .needs, text: message, date: session.needsInputSince ?? Date()))
                next += 1
            } else if case let .done(summary) = session.phase {
                // The transcript may not have the final reply flushed yet; the store does.
                if let summary, !summary.isEmpty, !base.suffix(3).contains(where: { $0.kind == .reply && $0.text?.hasPrefix(String(summary.prefix(40))) == true }) {
                    base.append(ThreadItem(id: next, kind: .reply, text: summary, date: session.finishedAt ?? Date()))
                    next += 1
                }
                base.append(ThreadItem(id: next, kind: .finished(failed: session.failed), text: nil, date: session.finishedAt ?? Date()))
            }
        }
        return base
    }

    private func showsTime(at index: Int) -> Bool {
        let list = items
        guard index > 0 else { return list[index].date != .distantPast }
        let gap = list[index].date.timeIntervalSince(list[index - 1].date)
        return list[index].date != .distantPast && gap > 15 * 60
    }

    private func timeLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today " + time }
        if calendar.isDateInYesterday(date) { return "Yesterday " + time }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " " + time
    }

    /// Reply bubbles in a row share one avatar, on the last of them, like Messages.
    private func isLastInRun(_ index: Int) -> Bool {
        let list = items
        guard index + 1 < list.count else { return true }
        return list[index + 1].kind != list[index].kind
    }
}

/// Avatar, name and where it runs, with the status on the right.
private struct ConversationHeader: View {
    let session: AgentSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                SessionIcon(session: session, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.projectName)
                            .font(DSFont.sans(16, .heavy))
                            .foregroundStyle(DS.Palette.textPrimary)
                            .lineLimit(1)
                        if session.agent.isCloud {
                            Image(systemName: "cloud.fill").font(.system(size: 11)).foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                    Text([session.place, session.agent.displayName].compactMap { $0 }.joined(separator: " · "))
                        .font(DSFont.sans(12, .medium))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusLine(session: session, now: context.date)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.bottom, 12)
        }
    }
}

private struct ThreadRow: View {
    let item: ThreadItem
    let session: AgentSession
    let lastInRun: Bool

    var body: some View {
        switch item.kind {
        case .prompt:
            HStack {
                Spacer(minLength: 80)
                Bubble(text: item.text ?? "", fill: DS.Palette.brand, foreground: .white, mine: true, tail: lastInRun)
            }
        case .reply:
            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    if lastInRun { AgentGlyph(agent: session.agent, size: 14).frame(width: 26, height: 26).background(Circle().fill(DS.Palette.card)) }
                    else { Color.clear.frame(width: 26, height: 26) }
                }
                Bubble(text: item.text ?? "", fill: DS.Palette.card, foreground: DS.Palette.textPrimary, mine: false, tail: lastInRun)
                Spacer(minLength: 80)
            }
        case let .step(tool):
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: tool)).font(.system(size: 10, weight: .semibold))
                Text([tool.map(Self.verb) ?? "Working", item.text].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(DSFont.sans(11.5, .medium))
            .foregroundStyle(DS.Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 1)
        case .needs:
            Label(item.text.map { "Needs your OK: " + $0 } ?? "Needs your OK", systemImage: "hand.raised.fill")
                .font(DSFont.sans(12, .semibold))
                .foregroundStyle(DS.Palette.gold)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(DS.Palette.gold.opacity(0.12)))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        case let .finished(failed):
            VStack(spacing: 6) {
                Label(failed ? "Failed" : "Done", systemImage: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(DSFont.sans(11.5, .semibold))
                    .foregroundStyle(failed ? DS.Palette.bad : DS.Palette.ok)
                // What the turn left behind: lines changed and how the tests went.
                if lastInRun { OutcomeBadges(session: session) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    static func verb(_ tool: String) -> String {
        switch stepLabel(tool) {
        case "Command": return "Ran a command"
        case "Edit": return "Edited"
        case "Read": return "Read"
        case "Web": return "Searched the web"
        case "Helper": return "Started a helper"
        case "Plan": return "Updated the plan"
        default: return "Used " + tool
        }
    }

    static func symbol(for tool: String?) -> String {
        switch tool.map(stepLabel) {
        case "Command": return "terminal"
        case "Edit": return "pencil"
        case "Read": return "doc.text.magnifyingglass"
        case "Web": return "globe"
        case "Helper": return "person.2"
        case "Plan": return "checklist"
        default: return "gearshape"
        }
    }
}

/// A Messages-style bubble: rounded, with a softer corner on the side it came from.
private struct Bubble: View {
    let text: String
    let fill: Color
    let foreground: Color
    let mine: Bool
    let tail: Bool

    var body: some View {
        Text(text)
            .font(DSFont.sans(13.5, .medium))
            .foregroundStyle(foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                BubbleShape(bottomLeading: !mine && tail ? 5 : 18, bottomTrailing: mine && tail ? 5 : 18)
                    .fill(fill)
            )
    }
}

/// The "…" bubble while the agent works, with what it's doing underneath.
private struct TypingBubble: View {
    let caption: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Color.clear.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(DS.Palette.textSecondary)
                                .frame(width: 7, height: 7)
                                .opacity(reduceMotion ? 0.7 : 0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(BubbleShape(bottomLeading: 5, bottomTrailing: 18).fill(DS.Palette.card))
                }
                Text(caption)
                    .font(DSFont.sans(11, .medium))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
            Spacer()
        }
        .padding(.top, 2)
    }
}

/// Where Messages has its reply box. Type and press Return:
/// - waiting on a permission prompt: denies it, and Claude reads your note as what to do instead
/// - working: queued, and Claude carries on with it the moment its turn ends
/// - otherwise: copied, and the session opens so you can paste it
private struct ComposerBar: View {
    @EnvironmentObject private var model: AppModel
    let session: AgentSession
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let route = model.replyRoute(for: session)
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            if let pending = model.pendingApproval(for: session) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(DS.Palette.gold)
                    Text(AppModel.approvalMessage(tool: pending.tool, detail: pending.detail))
                        .font(DSFont.sans(12.5, .semibold))
                        .foregroundStyle(DS.Palette.gold)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Deny") { model.decide(session, allow: false) }.buttonStyle(SecondaryButtonStyle())
                    if let rule = pending.rule {
                        Button("Always Allow") { model.alwaysAllow(session) }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("Allows \(rule) in this repo from now on")
                    }
                    Button("Allow") { model.decide(session, allow: true) }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, 10)
            }
            if let note = model.composerNotes[session.id] {
                Text(note)
                    .font(DSFont.sans(11.5, .medium))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                StopButton(session: session)
                HStack(spacing: 6) {
                    TextField(placeholder(route), text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(DSFont.sans(13.5, .medium))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(1...5)
                        .focused($focused)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? DS.Palette.textTertiary : DS.Palette.brand)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(help(route))
                }
                .padding(.leading, 14)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(focused ? 0.28 : 0.14), lineWidth: 1))
                if !session.phase.isActive {
                    Button("Dismiss") { withAnimation(DS.Motion.base) { model.dismiss(session) } }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, 12)
        }
        .padding(.bottom, 6)
    }

    private func send() {
        let text = draft
        draft = ""
        model.send(text, to: session)
    }

    private func placeholder(_ route: AppModel.ReplyRoute) -> String {
        switch route {
        case .denyWithNote: return "Tell Claude what to do instead…"
        case .queueLocal, .queueCloud: return "Reply. Claude picks it up when this step's done…"
        case .copyAndOpen: return session.phase.isActive ? "Reply (copies it and opens the session)…" : "Continue… (copies it and opens the session)"
        }
    }

    private func help(_ route: AppModel.ReplyRoute) -> String {
        switch route {
        case .denyWithNote: return "Denies the request and tells Claude what to do instead"
        case .queueLocal, .queueCloud: return "Queued: Claude continues with it the moment its turn ends"
        case .copyAndOpen: return "Copies your message and opens the session to paste it"
        }
    }
}

/// A colored line saying where the session stands, in plain words.
private struct StatusLine: View {
    let session: AgentSession
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(DSFont.sans(13, .semibold).monospacedDigit())
                .foregroundStyle(session.isWaiting ? DS.Palette.gold : DS.Palette.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    /// Done sessions say when and how long; the result itself is shown just below.
    private var text: String {
        guard case .done = session.phase else { return session.statusText(now: now) }
        var line = (session.failed ? "Failed " : "Done ") + AgentSession.relative(session.finishedAt ?? session.lastActivityAt, now: now).lowercased()
        if let took = session.cookDuration { line += " · took \(Format.duration(took))" }
        return line
    }

    private var color: Color {
        switch session.phase {
        case .needsInput: return DS.Palette.gold
        case .cooking: return DS.Palette.textSecondary
        case .done: return session.failed ? DS.Palette.bad : DS.Palette.ok
        case .idle: return DS.Palette.textTertiary
        }
    }
}

/// Lets one button pick its style at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// A rounded rectangle with its own bottom corners (macOS 13 has no uneven rounded rectangle).
struct BubbleShape: Shape {
    var radius: CGFloat = 18
    var bottomLeading: CGFloat
    var bottomTrailing: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        let bl = min(bottomLeading, rect.height / 2), br = min(bottomTrailing, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// "4 files · +120 −35" and "Tests passing", for a finished turn.
struct OutcomeBadges: View {
    let session: AgentSession

    var body: some View {
        if session.changes != nil || session.testsPassed != nil {
            HStack(spacing: 6) {
                if let changes = session.changes {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10, weight: .semibold))
                        Text("\(changes.files) file\(changes.files == 1 ? "" : "s")")
                        Text("+\(changes.additions)").foregroundStyle(DS.Palette.ok)
                        Text("−\(changes.deletions)").foregroundStyle(DS.Palette.bad)
                    }
                    .help(changes.paths.prefix(12).joined(separator: "\n"))
                    .badgeChip()
                }
                if let passed = session.testsPassed {
                    Label(passed ? "Tests passing" : "Tests failing", systemImage: passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(passed ? DS.Palette.ok : DS.Palette.bad)
                        .badgeChip()
                }
            }
            .font(DSFont.sans(11.5, .semibold).monospacedDigit())
            .foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

private extension View {
    func badgeChip() -> some View {
        padding(.horizontal, 9).frame(height: 24).background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

/// The 5-hour session limit first, then the week, from the Claude app's own numbers.
struct UsageMeter: View {
    let usage: PlanUsage
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            ring(usage.fiveHour)
            Text(compact ? "\(usage.fiveHour)%" : "Session \(usage.fiveHour)%")
                .foregroundStyle(color(usage.fiveHour))
            if let week = usage.week, !compact {
                Text("· Week \(week)%").foregroundStyle(week >= 80 ? color(week) : DS.Palette.textTertiary)
            }
        }
        .font(DSFont.sans(11.5, .semibold).monospacedDigit())
        .help("Claude plan usage: \(usage.fiveHour)% of the 5-hour session limit" + (usage.week.map { ", \($0)% of the weekly limit" } ?? "") + ". As of \(usage.recordedAt.formatted(date: .omitted, time: .shortened)).")
    }

    private func ring(_ percent: Int) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                .stroke(color(percent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }

    private func color(_ percent: Int) -> Color {
        percent >= 95 ? DS.Palette.bad : percent >= 80 ? DS.Palette.gold : DS.Palette.textSecondary
    }
}
