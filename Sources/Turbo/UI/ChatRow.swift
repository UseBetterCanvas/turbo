import SwiftUI
import TurboCore

extension AgentSession {
    /// The time on the right of a row: how long it's cooked or waited, or when it finished.
    func when(now: Date) -> String {
        switch phase {
        case .cooking:
            return Format.clock(now.timeIntervalSince(turnStartedAt ?? now))
        case .needsInput:
            return Format.clock(now.timeIntervalSince(needsInputSince ?? lastActivityAt))
        case .done, .idle:
            return Self.relative(finishedAt ?? lastActivityAt, now: now)
        }
    }

    /// One line under the name, like a chat preview.
    func preview(now: Date) -> String {
        var parts: [String] = []
        switch phase {
        case let .needsInput(message):
            parts.append(message ?? "Needs your OK")
        case .cooking:
            if let place { parts.append(place) }
            let silent = now.timeIntervalSince(lastActivityAt)
            parts.append(silent >= 300 ? "No activity for \(Format.duration(silent))" : (activityDetail ?? activity))
        case .done:
            if let place { parts.append(place) }
            if let summary = Format.snippet(summary, limit: 120) {
                parts.append(summary)
            } else if let duration = cookDuration {
                parts.append("\(failed ? "Failed after" : "Done in") \(Format.duration(duration))")
            } else {
                parts.append(failed ? "Failed" : "Done")
            }
        case .idle:
            parts.append(place ?? agent.displayName)
        }
        return parts.joined(separator: " · ")
    }

    static func relative(_ date: Date, now: Date) -> String {
        let ago = now.timeIntervalSince(date)
        if ago < 60 { return "Just now" }
        if ago < 3600 { return "\(Int(ago / 60))m ago" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if ago < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    var isWaiting: Bool {
        if case .needsInput = phase { return true }
        return false
    }
}

/// A session as a chat-style row: round avatar, name with the time on the right, a one-line
/// preview, and the one action that matters (Allow when it's waiting, otherwise Open).
struct ChatRow: View {
    @EnvironmentObject private var model: AppModel
    let session: AgentSession
    let now: Date
    /// The pop-up's sidebar uses a tighter row.
    var compact = false
    var showsAction = true

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            SessionIcon(session: session, size: compact ? 34 : 40)
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.projectName)
                        .font(DSFont.sans(compact ? 13 : 14, .bold))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if session.agent.isCloud {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: compact ? 9 : 10, weight: .semibold))
                            .foregroundStyle(DS.Palette.textTertiary)
                            .help("Runs in the cloud")
                    }
                    Spacer(minLength: 4)
                    Text(session.when(now: now))
                        .font(DSFont.sans(compact ? 11 : 12, .medium).monospacedDigit())
                        .foregroundStyle(session.isWaiting ? DS.Palette.gold : DS.Palette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(model.approvalErrors[session.id] ?? session.preview(now: now))
                    .font(DSFont.sans(compact ? 12 : 12.5, .medium))
                    .foregroundStyle(model.approvalErrors[session.id] != nil ? DS.Palette.bad : DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if showsAction { action }
        }
    }

    @ViewBuilder private var action: some View {
        if model.pendingApproval(for: session) != nil {
            Button {
                model.decide(session, allow: true)
            } label: {
                Text("Allow")
                    .font(DSFont.sans(12, .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(DS.Palette.gold))
            }
            .buttonStyle(PressableStyle())
            .help("Allow this once. Hover for Deny and more.")
        } else if model.canOpen(session) {
            Button {
                model.open(session)
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Palette.brand))
            }
            .buttonStyle(PressableStyle())
            .help(session.link != nil ? "Open the session" : "Go to its terminal")
        }
    }
}

/// Dips a little when pressed, like the island's own controls.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(DS.Motion.fast, value: configuration.isPressed)
    }
}

/// A small rounded pill for footers: "Connections +", "Visualizer".
struct ChipButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { label() }
                .font(DSFont.sans(12, .semibold))
                .foregroundStyle(DS.Palette.textPrimary.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.14 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

/// A round icon button: settings, quiet, expand, close.
struct RoundIconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 30
    var outlined = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(hovering ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : (outlined ? 0.04 : 0))))
                .overlay(Circle().strokeBorder(Color.white.opacity(outlined ? 0.18 : 0), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// The agents you've connected, as a little cluster of marks: the "+4 Apps" of Turbo.
struct ConnectedAgentsChip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        let agents = connected
        ChipButton(action: { model.openPopup(.settings) }) {
            HStack(spacing: -4) {
                ForEach(agents.prefix(3), id: \.self) { agent in
                    AgentGlyph(agent: agent, size: 12)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(DS.Palette.card))
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                }
            }
            if agents.count > 3 { Text("+\(agents.count - 3)") }
            Text(agents.isEmpty ? "Connect" : "Agents")
            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
        }
        .help("Connections")
    }

    private var connected: [Agent] {
        var list: [Agent] = []
        if model.claudeStopReady || model.lastHeard[.claude] != nil { list.append(.claude) }
        if prefs.cloudEnabled { list.append(.cloud) }
        if prefs.watchCodexSessions && model.lastHeard[.codex] != nil { list.append(.codex) }
        if prefs.watchCodexCloud && model.lastHeard[.codexCloud] != nil { list.append(.codexCloud) }
        if prefs.watchCoworkSessions && model.lastHeard[.cowork] != nil { list.append(.cowork) }
        return list
    }
}
