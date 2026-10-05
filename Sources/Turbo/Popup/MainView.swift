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
            .contextMenu {
                Button("Clear Finished") { model.clearFinished() }
                Button("Clear All") { model.clearAll() }
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

            let finished = model.sessions.filter { !$0.phase.isActive }.count
            if finished > 0 {
                Button { withAnimation(DS.Motion.base) { model.clearFinished() } } label: {
                    Label("Clear \(finished) Finished", systemImage: "checkmark.circle")
                        .font(DSFont.sans(12, .semibold))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(PressableStyle())
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .help("Removes finished sessions from the list. Right-click a session for Clear All.")
            }

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
            .overlay(alignment: .trailing) {
                // Clear it from the list right where you're looking.
                if hovering {
                    Button { withAnimation(DS.Motion.base) { model.dismiss(session) } } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.Palette.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(DS.Palette.overlay))
                    }
                    .buttonStyle(PressableStyle())
                    .hoverTip(session.phase.isActive ? "Remove (returns on new activity)" : "Remove")
                    .padding(.trailing, 10)
                    .transition(.opacity)
                }
            }
            .contextMenu {
                if model.canOpen(session) { Button("Open") { model.open(session) } }
                if model.stopMethod(for: session) != nil { Button("Stop") { model.stop(session) } }
                Divider()
                Button("Remove from Turbo") { model.dismiss(session) }
                Button("Clear Finished") { model.clearFinished() }
                    .disabled(!model.sessions.contains { !$0.phase.isActive })
                Button("Clear All") { model.clearAll() }
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
                        if session.agent == .cloud && !prefs.cloudShareTitles {
                            // One click to see the whole conversation, both ways.
                            VStack(spacing: 8) {
                                Text("See what you and Claude say here too: your prompts and Claude's replies.")
                                    .font(DSFont.sans(12, .medium))
                                    .foregroundStyle(DS.Palette.textSecondary)
                                    .multilineTextAlignment(.center)
                                Button("Turn On and Copy Setup Script") { model.turnOnCloudConversations() }
                                    .buttonStyle(SecondaryButtonStyle())
                                Text("Then paste it into your claude.ai/code environment. New sessions show the full chat.")
                                    .font(DSFont.sans(11, .medium))
                                    .foregroundStyle(DS.Palette.textTertiary)
                            }
                            .padding(.horizontal, 40)
                            .padding(.vertical, 10)
                        } else if items.isEmpty {
                            Text("The conversation shows up here as it happens.")
                                .font(DSFont.sans(12, .medium))
                                .foregroundStyle(DS.Palette.textTertiary)
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
                        ForEach(model.queuedReplies[session.id] ?? []) { reply in
                            let text = reply.text
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
            let thread = await Task.detached(priority: .utility) { ClaudeTranscript.thread(atPath: path, imageDirectory: AppModel.transcriptImageDirectory) }.value
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
    @EnvironmentObject private var model: AppModel
    let item: ThreadItem
    let session: AgentSession
    let lastInRun: Bool

    var body: some View {
        switch item.kind {
        case .prompt:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 4) {
                    if !item.images.isEmpty { PromptImages(urls: item.images) }
                    if let text = item.text, !text.isEmpty {
                        Bubble(text: text, fill: DS.Palette.brand, foreground: .white, mine: true, tail: lastInRun)
                    }
                }
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
            VStack(spacing: 8) {
                Label(item.text.map { "Needs your OK: " + $0 } ?? "Needs your OK", systemImage: "hand.raised.fill")
                    .font(DSFont.sans(12, .semibold))
                    .foregroundStyle(DS.Palette.gold)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(DS.Palette.gold.opacity(0.12)))
                // Turbo can't answer this one itself (no Allow bar below), so say where to go.
                if lastInRun, session.phase == .needsInput, model.pendingApproval(for: session) == nil {
                    HStack(spacing: 8) {
                        Text("Answer it in \(session.agent.displayName).")
                            .font(DSFont.sans(11.5, .medium))
                            .foregroundStyle(DS.Palette.textSecondary)
                        Button("Open Session") { model.open(session) }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Dismiss") { model.dismiss(session) }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
            }
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
        MarkdownText(markdown: text, foreground: foreground)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                BubbleShape(bottomLeading: !mine && tail ? 5 : 18, bottomTrailing: mine && tail ? 5 : 18)
                    .fill(fill)
            )
    }
}

/// Images you sent with a prompt, like photos in a message thread. Click one to open it.
private struct PromptImages: View {
    let urls: [URL]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(urls, id: \.self) { url in
                Button { NSWorkspace.shared.open(url) } label: { thumbnail(url) }
                    .buttonStyle(PressableStyle())
                    .help(url.lastPathComponent)
            }
        }
    }

    private var side: CGFloat { urls.count == 1 ? 200 : 110 }

    @ViewBuilder private func thumbnail(_ url: URL) -> some View {
        Group {
            if url.isFileURL {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    placeholder
                }
            } else {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var placeholder: some View {
        ZStack {
            DS.Palette.card
            Image(systemName: "photo").foregroundStyle(DS.Palette.textTertiary)
        }
    }
}

/// An agent reply laid out like chat: real lists, bold, code and headings instead of raw markdown.
private struct MarkdownText: View {
    let markdown: String
    let foreground: Color

    var body: some View {
        let blocks = MarkdownBlock.parse(markdown)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .foregroundStyle(foreground)
        .tint(foreground)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(DSFont.sans(level <= 2 ? 15 : 14, .bold))
        case .paragraph(let text):
            inline(text).font(DSFont.sans(13.5, .medium))
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(DSFont.sans(13.5, .semibold))
                    .opacity(0.7)
                    .frame(minWidth: 14, alignment: .trailing)
                inline(text).font(DSFont.sans(13.5, .medium))
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(foreground.opacity(0.4)).frame(width: 2)
                inline(text).font(DSFont.sans(13.5, .medium)).opacity(0.8)
            }
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(DSFont.mono(12))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
        case .rule:
            Rectangle().fill(foreground.opacity(0.2)).frame(height: 1)
        }
    }

    /// Bold, italic, `code` and links, keeping the text if the markdown doesn't parse.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let styled = try? AttributedString(markdown: text, options: options) { return Text(styled) }
        return Text(text)
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
    @State private var attachments: [URL] = []
    @State private var dropTargeted = false
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
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { file in
                            HStack(spacing: 5) {
                                Image(systemName: Self.symbol(for: file)).font(.system(size: 10, weight: .semibold))
                                Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
                                Button { attachments.removeAll { $0 == file } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(DS.Palette.textTertiary)
                            }
                            .font(DSFont.sans(11.5, .medium))
                            .foregroundStyle(DS.Palette.textPrimary)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, 10)
            }
            HStack(spacing: 8) {
                StopButton(session: session)
                HStack(spacing: 6) {
                    Menu {
                        Button("Choose Files…") { chooseFiles() }
                        Button("Paste Image") { if let image = model.pastedImageFile() { attachments.append(image) } }
                            .disabled(NSImage(pasteboard: NSPasteboard.general) == nil)
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Attach files or a pasted image. You can also drop files here.")
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
                            .foregroundStyle(canSend ? DS.Palette.brand : DS.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(help(route))
                }
                .padding(.leading, 14)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(dropTargeted ? DS.Palette.brand : Color.white.opacity(focused ? 0.28 : 0.14), lineWidth: dropTargeted ? 2 : 1))
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url else { return }
                            DispatchQueue.main.async { if !attachments.contains(url) { attachments.append(url) } }
                        }
                    }
                    return true
                }
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

    private var canSend: Bool {
        guard !model.uploadingSessions.contains(session.id) else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // While approval is pending a reply is a denial note, so it needs words.
        if model.replyRoute(for: session) == .denyWithNote { return hasText }
        return hasText || !attachments.isEmpty
    }

    private func send() {
        guard canSend else { return }
        let text = draft, files = attachments
        draft = ""
        attachments = []
        model.send(text, attachments: files, to: session) { text, files in
            // Upload failed: put everything back so it can be retried.
            if draft.isEmpty { draft = text }
            attachments = files + attachments.filter { !files.contains($0) }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            attachments += panel.urls.filter { !attachments.contains($0) }
        }
    }

    static func symbol(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
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

/// The 5-hour session limit first, then the week, from the Claude app's own numbers. Hover it
/// for the full picture: both limits, when they reset, and a link to the breakdown.
struct UsageMeter: View {
    @EnvironmentObject private var model: AppModel
    let usage: PlanUsage
    var compact = false
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        HStack(spacing: 6) {
            UsageRing(percent: usage.fiveHour)
            Text(compact ? "\(usage.fiveHour)%" : "Session \(usage.fiveHour)%")
                .foregroundStyle(UsageRing.color(usage.fiveHour))
            if let week = usage.week, !compact {
                Text("· Week \(week)%").foregroundStyle(week >= 80 ? UsageRing.color(week) : DS.Palette.textTertiary)
            }
        }
        .font(DSFont.sans(11.5, .semibold).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.25 : 0.45)) {
                // Stay open while the pointer is on the meter or on the panel itself.
                let keep = hovering || model.usagePanelHovered
                if keep != showing { showing = keep }
            }
        }
        .onTapGesture { showing.toggle() }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            UsageDetails(usage: usage, onHover: { inside in
                model.usagePanelHovered = inside
                if !inside {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        if !hovering && !model.usagePanelHovered { showing = false }
                    }
                }
            })
            .environmentObject(model)
        }
        .onChange(of: showing) { open in model.setUsageDetailsOpen(open) }
    }
}

/// A small ring that fills with the percentage.
struct UsageRing: View {
    let percent: Int
    var size: CGFloat = 13

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                .stroke(Self.color(percent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }

    static func color(_ percent: Int) -> Color {
        percent >= 95 ? DS.Palette.bad : percent >= 80 ? DS.Palette.gold : DS.Palette.textSecondary
    }
}

/// The panel behind the meter, like Claude's own: each limit with a bar and when it resets.
struct UsageDetails: View {
    let usage: PlanUsage
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                } label: {
                    HStack {
                        Text("Plan usage limits").font(DSFont.sans(12.5, .semibold)).foregroundStyle(DS.Palette.textSecondary)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Palette.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                limit("Session limit", percent: usage.fiveHour, resets: usage.sessionResetsAt, now: context.date, trend: usage.sessionTrend)
                if let week = usage.week {
                    limit("Weekly · all models", percent: week, resets: usage.weekResetsAt, now: context.date, trend: [])
                }

                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                HStack {
                    Button("See Detailed Breakdown") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Text("As of \(usage.recordedAt.formatted(date: .omitted, time: .shortened))")
                        .font(DSFont.sans(11, .medium))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .padding(16)
            .frame(width: 340)
        }
        .background(DS.Palette.card)
        .environment(\.colorScheme, .dark)
        .onHover(perform: onHover)
    }

    private func limit(_ title: String, percent: Int, resets: Date?, now: Date, trend: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(DSFont.sans(13.5, .semibold)).foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                if let resets {
                    Text(resetText(resets, now: now)).font(DSFont.sans(12, .medium)).foregroundStyle(DS.Palette.textTertiary)
                }
                Text("\(percent)%").font(DSFont.sans(13, .bold).monospacedDigit()).foregroundStyle(percent >= 80 ? UsageRing.color(percent) : DS.Palette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(percent >= 80 ? UsageRing.color(percent) : DS.Palette.brand)
                        .frame(width: max(4, geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100))
                }
            }
            .frame(height: 5)
        }
    }

    /// "Resets in about 3 hr 26 min", or the day and time when it's further off.
    private func resetText(_ date: Date, now: Date) -> String {
        let left = date.timeIntervalSince(now)
        guard left > 0 else { return "" }
        if left < 86_400 {
            let h = Int(left) / 3600, m = (Int(left) % 3600) / 60
            return "Resets in about " + (h > 0 ? "\(h) hr \(m) min" : "\(m) min")
        }
        return "Resets about " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
