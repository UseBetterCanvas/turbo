import SwiftUI
import TurboCore

/// Every session at a glance, most urgent first: Needs You, Cooking, Done.
struct SessionsPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        let board = model.board

        VStack(alignment: .leading, spacing: DS.Space.xl) {
            HStack(alignment: .top) {
                PageHeader(title: "Sessions", subtitle: headline(board))
                Spacer()
                BCSegmented(options: [
                    SegmentOption(value: CookMode.island, label: "Island", symbol: "capsule"),
                    SegmentOption(value: CookMode.visualizer, label: "Visualizer", symbol: "sparkles"),
                ], selection: $prefs.mode)
                .frame(width: 220)
                .help("Island: a heads-up in the notch. Visualizer: plus a light show while agents work.")
            }

            if let error = model.serverError {
                Callout(symbol: "exclamationmark.triangle.fill", text: error, tone: .bad)
            }
            if !Integrations.isClaudeInstalled && !prefs.cloudEnabled {
                SetupNudge()
            }

            if board.all.isEmpty {
                EmptyState(
                    symbol: "pawprint",
                    title: "Nothing cooking",
                    message: "Start a session in Claude Code, Codex or Cowork, on this Mac or in the cloud, and it shows up here."
                ) {
                    Button {
                        model.simulateBusyDay()
                    } label: {
                        Label("Play a Busy Day", systemImage: "play.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                BoardSection(title: "Needs You", tone: .attention, sessions: board.needsYou)
                BoardSection(title: "Cooking", tone: .info, sessions: board.cooking)
                BoardSection(title: "Done", tone: .good, sessions: board.done) {
                    Button("Clear Done") { withAnimation(DS.Motion.base) { model.clearFinished() } }
                        .buttonStyle(GhostButtonStyle())
                }
            }
        }
    }

    private func headline(_ board: SessionBoard) -> String {
        if board.all.isEmpty { return "Everything your agents are working on, in one place." }
        var parts: [String] = []
        if !board.needsYou.isEmpty { parts.append("\(board.needsYou.count) waiting on you") }
        if !board.cooking.isEmpty { parts.append("\(board.cooking.count) cooking") }
        if !board.done.isEmpty { parts.append("\(board.done.count) done") }
        return parts.joined(separator: " · ")
    }
}

private struct BoardSection<Trailing: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let tone: StatusTone
    let sessions: [AgentSession]
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, tone: StatusTone, sessions: [AgentSession], @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.tone = tone
        self.sessions = sessions
        self.trailing = trailing
    }

    var body: some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Circle().fill(tone.color).frame(width: 7, height: 7)
                    Eyebrow(text: "\(title) · \(sessions.count)")
                    Spacer()
                    trailing()
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: DS.Space.s) {
                        ForEach(sessions) { session in
                            SessionCard(session: session, now: context.date)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
            .animation(DS.Motion.base, value: sessions.map(\.id))
        }
    }
}

extension BoardSection where Trailing == EmptyView {
    init(title: String, tone: StatusTone, sessions: [AgentSession]) {
        self.init(title: title, tone: tone, sessions: sessions) { EmptyView() }
    }
}

/// One session: who, where, how long, and one obvious way to get to it.
struct SessionCard: View {
    @EnvironmentObject private var model: AppModel
    let session: AgentSession
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.m) {
            ZStack(alignment: .bottomTrailing) {
                IconTile(symbol: session.agent.symbol, tint: session.agent.tint, size: 36)
                statusDot.offset(x: 3, y: 3)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.s) {
                    Text(session.projectName)
                        .font(DS.Typography.headline)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(1)
                    Text(session.agent.displayName)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(DS.Typography.caption.monospacedDigit())
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .numericTransition()
            }

            Spacer(minLength: DS.Space.s)

            HStack(spacing: DS.Space.s) {
                if hovering, !session.phase.isActive {
                    Button {
                        withAnimation(DS.Motion.base) { model.dismiss(session) }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Dismiss")
                }
                if canOpen {
                    Button(openLabel) { model.open(session) }
                        .buttonStyle(BCButtonStyle(variant: isWaiting ? .primary : .secondary, size: .sm))
                } else {
                    StatusPill(text: badgeText, tone: badgeTone)
                }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.m)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .fill(hovering ? DS.Palette.overlay : DS.Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(isWaiting ? DS.Palette.gold.opacity(0.45) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(session) }
        .contextMenu {
            if canOpen { Button(openLabel) { model.open(session) } }
            Button("Dismiss") { model.dismiss(session) }
        }
        .animation(hovering ? nil : DS.Motion.out, value: hovering)
    }

    private var isWaiting: Bool {
        if case .needsInput = session.phase { return true }
        return false
    }

    private var canOpen: Bool {
        session.link != nil || session.hostAppBundleID != nil
    }

    private var openLabel: String {
        if session.link != nil { return "Open Session" }
        return isWaiting ? "Respond" : "Open"
    }

    private var detail: String {
        switch session.phase {
        case let .needsInput(message):
            return message ?? "Waiting on a permission prompt"
        case .done:
            if let summary = Format.snippet(session.summary, limit: 90) { return summary }
            return session.statusText(now: now)
        case .cooking:
            var text = session.statusText(now: now)
            if session.beats > 0 { text += " · \(session.beats) step\(session.beats == 1 ? "" : "s")" }
            if let tool = session.lastTool { text += " · \(tool)" }
            return text
        case .idle:
            return "Idle"
        }
    }

    private var detailColor: Color {
        isWaiting ? DS.Palette.gold : DS.Palette.textSecondary
    }

    private var badgeText: String {
        switch session.phase {
        case .needsInput: return "Needs you"
        case .cooking: return "Cooking"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    private var badgeTone: StatusTone {
        switch session.phase {
        case .needsInput: return .attention
        case .cooking: return .info
        case .done: return .good
        case .idle: return .neutral
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        let color: Color = {
            switch session.phase {
            case .needsInput: return DS.Palette.gold
            case .cooking: return DS.Palette.brandText
            case .done: return DS.Palette.ok
            case .idle: return DS.Palette.textTertiary
            }
        }()
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(DS.Palette.card, lineWidth: 2))
    }
}

/// Shown until at least one agent is connected.
private struct SetupNudge: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            HStack(spacing: DS.Space.m) {
                IconTile(symbol: "link", tint: DS.Palette.brandText, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Your Agents").font(DS.Typography.headline)
                    Text("Claude Code needs one click. Cloud sessions need one setup script. Codex and Cowork just work.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Set Up") { model.popupPage = .agents }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}
