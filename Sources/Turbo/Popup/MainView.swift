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

            HStack(spacing: 8) {
                ConnectedAgentsChip()
                ChipButton(action: { model.setQuiet(for: model.isQuiet ? nil : 3600) }) {
                    Image(systemName: model.isQuiet ? "bell.slash.fill" : "bell").font(.system(size: 11, weight: .semibold))
                    Text(model.isQuiet ? "Quiet" : "Alerts On")
                }
                .help(model.isQuiet ? "Turn alerts back on" : "Quiet for 1 hour")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 12)

            UserRow()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
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
                Text(summary).font(DSFont.sans(11.5, .medium)).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            RoundIconButton(symbol: "info.circle", help: "Welcome tour", size: 28) { model.showOnboarding() }
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

/// One session in full: what was asked, what it's doing, and every action that applies.
private struct SessionPane: View {
    @EnvironmentObject private var model: AppModel
    let session: AgentSession
    @State private var latest: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack(spacing: 14) {
                        SessionIcon(session: session, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.projectName)
                                .font(DSFont.display(22))
                                .foregroundStyle(DS.Palette.textPrimary)
                                .lineLimit(2)
                            Text([session.place, session.agent.displayName, session.when(now: context.date)].compactMap { $0 }.joined(separator: " · "))
                                .font(DSFont.sans(13, .medium).monospacedDigit())
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                        Spacer()
                    }

                    StatusLine(session: session, now: context.date)

                    if let prompt = session.lastPrompt {
                        section("Asked", prompt)
                    }
                    if let text = latest ?? Format.snippet(session.summary, limit: 600) {
                        section(session.phase.isActive ? "Latest" : "Result", text)
                    }
                    if !session.recentSteps.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: "Steps")
                            HStack(spacing: 6) {
                                ForEach(Array(session.recentSteps.suffix(6).enumerated()), id: \.offset) { _, tool in
                                    Text(stepLabel(tool))
                                        .font(DSFont.sans(11.5, .bold))
                                        .foregroundStyle(DS.Palette.textPrimary.opacity(0.85))
                                        .padding(.horizontal, 9)
                                        .frame(height: 24)
                                        .background(Capsule().fill(Color.white.opacity(0.08)))
                                }
                            }
                        }
                    }
                    if session.lastPrompt == nil && latest == nil && session.summary == nil && session.agent.isCloud {
                        Text("Cloud sessions share progress, not prompts or replies. Turn on Name Cloud Sessions in Settings to see what each one was asked.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    actions
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.bottom, DS.Space.xl)
                .padding(.top, DS.Space.s)
            }
        }
        .task(id: session.lastActivityAt) {
            guard let path = session.transcriptPath else { return }
            let text = await Task.detached(priority: .utility) { ClaudeTranscript.lastAssistantText(atPath: path, currentTurnOnly: true) }.value
            guard !Task.isCancelled else { return }
            latest = Format.snippet(text, limit: 600)
        }
    }

    private func section(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: label)
            Text(text)
                .font(DSFont.sans(13.5, .medium))
                .foregroundStyle(DS.Palette.textPrimary.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.card))
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if let pending = model.pendingApproval(for: session) {
                Button("Allow") { model.decide(session, allow: true) }
                    .buttonStyle(PrimaryButtonStyle())
                if let rule = pending.rule {
                    Button("Always Allow") { model.alwaysAllow(session) }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Allows \(rule) in this repo from now on")
                }
                Button("Deny") { model.decide(session, allow: false) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            StopButton(session: session)
            if model.canOpen(session) {
                Button(session.link != nil ? "Open Session" : "Go to Terminal") { model.open(session) }
                    .buttonStyle(model.pendingApproval(for: session) == nil ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
            }
            Spacer()
            if !session.phase.isActive {
                Button("Dismiss") {
                    withAnimation(DS.Motion.base) { model.dismiss(session) }
                }
                .buttonStyle(GhostButtonStyle())
            }
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
            Text(session.statusText(now: now))
                .font(DSFont.sans(13, .semibold).monospacedDigit())
                .foregroundStyle(session.isWaiting ? DS.Palette.gold : DS.Palette.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(color.opacity(0.12)))
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
