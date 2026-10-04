import SwiftUI
import TurboCore

/// Every session in one list, most urgent first. One row per session, one obvious action.
struct SessionsPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        let board = model.board

        VStack(alignment: .leading, spacing: DS.Space.l) {
            if let error = model.serverError {
                Callout(symbol: "", text: error, tone: .bad)
            }
            UpdateBanner(updater: model.updater)
            if !Integrations.isClaudeInstalled && !prefs.cloudEnabled {
                SetupBanner()
            }

            if board.all.isEmpty {
                EmptyState(
                    symbol: "pawprint",
                    title: "Nothing cooking",
                    message: "Start a session in Claude Code, Codex or Cowork and it shows up here."
                ) {
                    Button("Try a Demo") {
                        model.closePopup()
                        model.simulateBusyDay()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, DS.Space.xl)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        SessionGroup(title: "Needs you", tone: .attention, sessions: board.needsYou, now: context.date)
                        SessionGroup(title: "Cooking", tone: .info, sessions: board.cooking, now: context.date)
                        SessionGroup(title: "Done", tone: .good, sessions: board.done, now: context.date) {
                            Button("Clear") { withAnimation(DS.Motion.base) { model.clearFinished() } }
                                .buttonStyle(.plain)
                                .font(DSFont.sans(12, .semibold))
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

private struct SessionGroup<Trailing: View>: View {
    let title: String
    let tone: StatusTone
    let sessions: [AgentSession]
    let now: Date
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, tone: StatusTone, sessions: [AgentSession], now: Date, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.tone = tone
        self.sessions = sessions
        self.now = now
        self.trailing = trailing
    }

    var body: some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: 6) {
                    Eyebrow(text: title)
                    Text("\(sessions.count)")
                        .font(DSFont.sans(10.5, .heavy).monospacedDigit())
                        .foregroundStyle(tone.color)
                    Spacer()
                    trailing()
                }
                .padding(.horizontal, DS.Space.xs)

                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { RowDivider().padding(.leading, 56) }
                        SessionRowView(session: session, now: now)
                    }
                }
                .background(RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous).fill(DS.Palette.card))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous))
            }
            .animation(DS.Motion.base, value: sessions.map(\.id))
        }
    }
}

extension SessionGroup where Trailing == EmptyView {
    init(title: String, tone: StatusTone, sessions: [AgentSession], now: Date) {
        self.init(title: title, tone: tone, sessions: sessions, now: now) { EmptyView() }
    }
}

/// One session: status dot on the agent icon, project and one line of detail, and Open.
struct SessionRowView: View {
    @EnvironmentObject private var model: AppModel
    let session: AgentSession
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.m) {
            ZStack(alignment: .bottomTrailing) {
                IconTile(symbol: session.agent.symbol, tint: session.agent.tint, size: 32)
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(DS.Palette.card, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName)
                    .font(DSFont.sans(13.5, .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(DSFont.sans(12, .medium).monospacedDigit())
                    .foregroundStyle(isWaiting ? DS.Palette.gold : DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: DS.Space.s)

            if hovering, !session.phase.isActive {
                Button {
                    withAnimation(DS.Motion.base) { model.dismiss(session) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Palette.textTertiary)
                .help("Dismiss")
            }
            if canOpen {
                Button(isWaiting ? "Respond" : "Open") { model.open(session) }
                    .buttonStyle(BCButtonStyle(variant: isWaiting ? .primary : .secondary, size: .sm))
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 10)
        .background(hovering ? DS.Palette.overlay : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(session) }
        .contextMenu {
            if canOpen { Button("Open") { model.open(session) } }
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

    private var dotColor: Color {
        switch session.phase {
        case .needsInput: return DS.Palette.gold
        case .cooking: return DS.Palette.brandText
        case .done: return session.failed ? DS.Palette.bad : DS.Palette.ok
        case .idle: return DS.Palette.textTertiary
        }
    }

    /// "Claude Code · 4:12 · Bash", "Codex · cooked in 3m 12s · Fixed the bug"
    private var detail: String {
        var parts = [session.agent.displayName]
        switch session.phase {
        case let .needsInput(message):
            parts.append(message ?? "Waiting on a permission prompt")
        case .cooking:
            if let start = session.turnStartedAt { parts.append(Format.clock(now.timeIntervalSince(start))) }
            if let tool = session.lastTool { parts.append(tool) }
        case .done:
            if session.failed { parts.append("Failed") }
            if let duration = session.cookDuration { parts.append("\(session.failed ? "ran for" : "cooked in") \(Format.duration(duration))") }
            if let summary = Format.snippet(session.summary, limit: 80) { parts.append(summary) }
        case .idle:
            parts.append("Idle")
        }
        return parts.joined(separator: " · ")
    }
}

/// Shown on the board when a new version is ready.
private struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if updater.updateAvailable {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Palette.brandText)
                Text("A new version of Turbo is ready.")
                    .font(DS.Typography.bodyStrong)
                Spacer()
                Button("Update") { Task { await updater.install() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.card))
        }
    }
}

/// A slim one-line prompt until something is connected.
private struct SetupBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.brandText)
            Text("Connect your agents so Turbo can hear them.")
                .font(DS.Typography.bodyStrong)
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer()
            Button("Set Up") { model.popupPage = .settings }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.brand.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(DS.Palette.brand.opacity(0.35), lineWidth: 1))
    }
}
