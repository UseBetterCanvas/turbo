import TurboCore
import Combine
import SwiftUI

struct IslandView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var state: IslandState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = model.presentation
        let geometry = state.geometry
        let size = IslandLayout.size(for: presentation, geometry: geometry, rows: model.sessions.count, detail: model.detailSessionID != nil, peek: model.peekText != nil)
        // The tiny island swells a touch under the pointer, a beat before it opens.
        let lifted = (presentation == .compact || presentation == .idle) && model.pointerInside

        VStack(spacing: 0) {
            Color.clear.frame(height: IslandLayout.topInset(geometry))

            ZStack(alignment: .top) {
                IslandBackground(presentation: presentation, docked: geometry.docked, size: size, attention: needsAttention)

                content(for: presentation, geometry: geometry)
                    .padding(.horizontal, geometry.docked ? IslandLayout.topRadius(for: presentation) : 0)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipShape(Rectangle())
            }
            .frame(width: size.width, height: size.height)
            .opacity(size.height == 0 ? 0 : 1)
            .scaleEffect(lifted && !reduceMotion ? 1.035 : 1, anchor: .top)
            .contentShape(Rectangle())
            .onTapGesture { model.islandTapped() }

            Spacer(minLength: 0)
        }
        .frame(width: IslandLayout.canvasSize.width, height: IslandLayout.canvasSize.height, alignment: .top)
        .animation(animation(for: presentation), value: presentation)
        .animation(animation(for: presentation), value: geometry)
        .animation(DS.Motion.slow, value: model.sessions.count)
        .animation(DS.Motion.slow, value: lifted)
        .animation(reduceMotion ? DS.Motion.fast : DS.Motion.dialogOpen, value: model.peekText)
        .preferredColorScheme(.dark)
    }

    /// BetterCampus dialog curves: a confident open, a quick close.
    private func animation(for presentation: IslandPresentation) -> Animation {
        if reduceMotion { return DS.Motion.fast }
        return presentation.isExpanded ? DS.Motion.dialogOpen : DS.Motion.dialogClose
    }

    private var needsAttention: Bool {
        model.active.contains { if case .needsInput = $0.phase { return true } else { return false } }
    }

    @ViewBuilder
    private func content(for presentation: IslandPresentation, geometry: NotchGeometry) -> some View {
        switch presentation {
        case .hidden:
            Color.clear
        case .idle:
            IdleIsland(geometry: geometry)
                .transition(.blurFade)
        case .compact:
            CompactIsland(sessions: model.active, geometry: geometry)
                .transition(.blurFade)
        case let .spotlight(spotlight):
            SpotlightCard(spotlight: spotlight)
                .padding(.top, IslandLayout.headroom(geometry))
                .transition(.blurFade)
                .id(spotlight.session.id + "\(spotlight.kind)")
        case .list:
            ZStack(alignment: .top) {
                SessionList(sessions: model.board.all, geometry: geometry)
                    .padding(.top, IslandLayout.headroom(geometry) + 4)
                // Docked, the controls sit in the strip beside the notch.
                if geometry.docked {
                    ListTopBar(geometry: geometry).frame(height: IslandLayout.headroom(geometry))
                }
            }
            .transition(.blurFade)
        }
    }
}

extension IslandPresentation {
    var isExpanded: Bool {
        switch self {
        case .spotlight, .list: return true
        case .hidden, .idle, .compact: return false
        }
    }
}

// MARK: Background

/// The black silhouette: notch-shaped when docked, a floating capsule/card when sharing the
/// notch with another app. Breathes amber while an agent waits on you.
private struct IslandBackground: View {
    let presentation: IslandPresentation
    let docked: Bool
    let size: CGSize
    let attention: Bool
    @State private var breathe = false

    var body: some View {
        ZStack {
            if docked {
                let shape = NotchShape(
                    topRadius: IslandLayout.topRadius(for: presentation),
                    bottomRadius: IslandLayout.bottomRadius(for: presentation)
                )
                shape.fill(Color.black)
                shape.stroke(DS.Palette.gold.opacity(attention ? (breathe ? 0.75 : 0.2) : 0), lineWidth: 1.5)
            } else {
                let shape = RoundedRectangle(cornerRadius: presentation == .compact || presentation == .idle ? size.height / 2 : 24, style: .continuous)
                shape.fill(Color.black)
                shape.stroke(Color.white.opacity(0.09), lineWidth: 1)
                shape.stroke(DS.Palette.gold.opacity(attention ? (breathe ? 0.75 : 0.2) : 0), lineWidth: 1.5)
            }
        }
        .shadow(color: .black.opacity(presentation.isExpanded || !docked ? 0.45 : 0), radius: 16, y: 7)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

// MARK: Compact: flanks the notch like a Live Activity

private struct CompactIsland: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sessions: [AgentSession]
    let geometry: NotchGeometry
    @State private var beat = 0
    @State private var glow = false

    var body: some View {
        let lead = model.lead
        let waitingCount = sessions.filter { if case .needsInput = $0.phase { return true } else { return false } }.count
        let waiting = waitingCount > 0
        let cookingCount = sessions.count - waitingCount
        let allAgents = Array(Set(sessions.map(\.agent))).sorted { $0.rawValue < $1.rawValue }
        let agents = Array(allAgents.prefix(2))

        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                // Leading: what's cooking.
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(glow ? 0.3 : 0))
                            .frame(width: 22, height: 22)
                            .blur(radius: 5)
                        if waiting {
                            AttentionHand(size: 12)
                        } else {
                            // Cooking is neutral. Color is saved for what needs you.
                            CookingFlame(tint: DS.Palette.textPrimary, size: 13)
                                .scaleEffect(glow && !reduceMotion ? 1.18 : 1, anchor: .bottom)
                        }
                    }
                    if waiting {
                        HStack(spacing: -3) {
                            ForEach(agents, id: \.self) { agent in
                                AgentBadge(agent: agent, size: 15)
                                    .background(Circle().fill(.black).padding(-1))
                            }
                        }
                    } else {
                        // Running: little level bars that jump with every step, like Now Playing.
                        ActivityBars(boost: glow, paused: reduceMotion)
                    }
                }
                .frame(width: IslandLayout.compactSideWidth, alignment: .center)

                // Center: hidden behind the notch when docked; a label when floating.
                Group {
                    if geometry.docked && geometry.hasNotch {
                        Color.clear
                    } else {
                        Text(waiting ? "Needs you" : (sessions.count > 1 ? "\(sessions.count) cooking" : (lead?.projectName ?? "Cooking")))
                            .font(DSFont.sans(11.5, .bold))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity)

                // Trailing: how long it's been on the stove.
                HStack(spacing: 5) {
                    // How long the lead has been waiting on you, or cooking.
                    if let start = lead?.needsInputSince ?? lead?.turnStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let text = Format.clock(context.date.timeIntervalSince(start))
                            Text(text)
                                .font(DSFont.sans(11.5, .bold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.92))
                                .numericTransition()
                                .animation(DS.Motion.slow, value: text)
                        }
                    }
                    // Who's waiting (gold) and who's cooking (white), at a glance.
                    if waiting {
                        CountPill(count: waitingCount, fill: DS.Palette.gold)
                            .help("\(waitingCount) need you")
                    }
                    if cookingCount > 1 || (waiting && cookingCount > 0) {
                        CountPill(count: cookingCount, fill: DS.Palette.textPrimary)
                            .help("\(cookingCount) cooking")
                    }
                }
                .frame(width: IslandLayout.compactSideWidth, alignment: .center)
            }
            .frame(height: geometry.docked ? geometry.notchSize.height : IslandLayout.floatingCompactHeight)

            }
                if let peek = model.peekText {
                    // The step it just moved on to, like a Live Activity update.
                    HStack(spacing: 6) {
                        if let lead { AgentGlyph(agent: lead.agent, size: 10) }
                        Text(peek)
                            .font(DSFont.sans(11.5, .semibold))
                            .foregroundStyle(DS.Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: IslandLayout.peekHeight)
                    .frame(maxWidth: .infinity)
                    .transition(.blurFade)
                    .id(peek)
                }
        }
        // Every tool call is a heartbeat.
        .onReceive(model.pulses.filter { $0.kind == .beat || $0.kind == .start }) { _ in
            withAnimation(.easeOut(duration: 0.12)) { glow = true }
            withAnimation(.easeIn(duration: 0.5).delay(0.12)) { glow = false }
        }
    }
}

private struct CountPill: View {
    let count: Int
    let fill: Color

    var body: some View {
        Text("\(count)")
            .font(DSFont.mono(10.5, .bold))
            .foregroundStyle(.black)
            .frame(minWidth: 16, minHeight: 16)
            .padding(.horizontal, count > 9 ? 3 : 0)
            .background(Capsule().fill(fill))
            .transition(.opacity)
    }
}

// MARK: Spotlight: the "it's done" moment

private struct SpotlightCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    let spotlight: Spotlight

    private var hasApproval: Bool {
        spotlight.kind == .needsInput && model.pendingApproval(for: spotlight.session) != nil
    }

    var body: some View {
        let session = spotlight.session
        let hovering = model.pointerInside

        ZStack(alignment: .topTrailing) {
            HStack(alignment: .center, spacing: 14) {
                Group {
                    if spotlight.kind == .finished && !session.failed {
                        SuccessMark(tint: DS.Palette.ok, size: 48)
                    } else if spotlight.kind == .finished {
                        ZStack {
                            Circle().fill(DS.Palette.bad.opacity(0.18))
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(DS.Palette.bad)
                        }
                        .frame(width: 48, height: 48)
                    } else {
                        ZStack {
                            Circle().fill(DS.Palette.gold.opacity(0.18))
                            AttentionHand(size: 20)
                        }
                        .frame(width: 48, height: 48)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        AgentGlyph(agent: session.agent, size: 12)
                        if session.agent.isCloud {
                            Image(systemName: "cloud.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                        Text(title(for: session))
                            .font(DSFont.sans(14, .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .staggered(0)

                    Text(subtitle(for: session))
                        .font(DSFont.sans(11.5, .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .staggered(1)

                    if let detail = detail(for: session) {
                        Text(detail)
                            .font(DSFont.sans(11.5))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .staggered(2)
                    }
                }
                Spacer(minLength: 0)
                // Answer the permission prompt right here.
                if spotlight.kind == .needsInput, model.pendingApproval(for: session) != nil {
                    VStack(spacing: 6) {
                        Button("Allow") {
                            model.decide(session, allow: true)
                        }
                        .buttonStyle(BCButtonStyle(variant: .primary, size: .sm, fullWidth: true))
                        Button("Deny") {
                            model.decide(session, allow: false)
                        }
                        .buttonStyle(BCButtonStyle(variant: .secondary, size: .sm, fullWidth: true))
                    }
                    .frame(width: 84)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 14)

            // More waiting their turn.
            if !model.spotlightQueue.isEmpty {
                Text("+\(model.spotlightQueue.count) more")
                    .font(DSFont.sans(10.5, .heavy))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .padding(.top, 10)
                    .padding(.trailing, 16)
                    .opacity(hovering || hasApproval ? 0 : 1)
            }

            // Hover affordances: one click to the thread, and a way out. Hidden while Allow /
            // Deny are showing, which sit in the same corner.
            HStack(spacing: 6) {
                if session.link != nil || session.hostAppBundleID != nil {
                    Button("Open") {
                        model.open(session)
                        model.advanceSpotlight()
                    }
                    .buttonStyle(BCButtonStyle(variant: .secondary, size: .sm))
                    .controlSize(.small)
                }
                Button {
                    model.markSeen(session)
                    model.advanceSpotlight()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
            .padding(.trailing, 14)
            .opacity(hovering && !hasApproval ? 1 : 0)
            .allowsHitTesting(hovering && !hasApproval)
            .offset(y: hovering ? 0 : -4)
            .animation(DS.Motion.slow, value: hovering)
        }
        .overlay(alignment: .bottom) {
            if spotlight.kind == .finished {
                CountdownBar(seconds: model.spotlightSeconds, tint: DS.Palette.ok)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 6)
                    .opacity(hovering ? 0 : 1)
                    .animation(DS.Motion.base, value: hovering)
            }
        }
    }

    private func title(for session: AgentSession) -> String {
        switch spotlight.kind {
        // Outcome first, so a long name is what gets cut.
        case .finished: return session.failed ? "Failed: \(session.projectName)" : "Done: \(session.projectName)"
        case .needsInput: return "Needs you: \(session.projectName)"
        }
    }

    private func subtitle(for session: AgentSession) -> String {
        if spotlight.kind == .finished, let duration = session.cookDuration {
            return [session.place ?? session.agent.displayName, Format.duration(duration)].joined(separator: " · ")
        }
        return session.place ?? session.agent.displayName
    }

    private func detail(for session: AgentSession) -> String? {
        switch session.phase {
        case let .needsInput(message): return message ?? "Waiting on a permission prompt."
        case let .done(summary): return Format.snippet(summary)
        default: return nil
        }
    }
}

// MARK: List: everything on the stove (on hover)

private struct SessionList: View {
    @EnvironmentObject private var model: AppModel
    let sessions: [AgentSession]
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            // Floating (no notch to sit beside), the controls get their own row.
            if !geometry.docked {
                ListTopBar(geometry: geometry).frame(height: IslandLayout.listTopBarHeight(geometry))
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 0) {
                    if sessions.isEmpty {
                        HStack(spacing: 12) {
                            AppIconView(size: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Nothing cooking").font(DSFont.sans(14, .bold)).foregroundStyle(.white)
                                Text("Start a session and it'll show up here.")
                                    .font(DSFont.sans(12.5, .medium))
                                    .foregroundStyle(DS.Palette.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: IslandLayout.rowHeight)
                        .staggered(0)
                    }
                    // Scrolls past five sessions; resting on one opens its details below it.
                    ScrollView(.vertical, showsIndicators: sessions.count > IslandLayout.maxRows) {
                        VStack(spacing: 0) {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                IslandChatRow(session: session, now: context.date, divider: index > 0)
                                    .frame(height: IslandLayout.rowHeight)
                                    .onHover { inside in hoverRow(session, inside) }
                                    .staggered(index)
                                if model.detailSessionID == session.id {
                                    SessionDetail(session: session)
                                        .frame(height: IslandLayout.detailHeight)
                                        .transition(.opacity)
                                }
                            }
                        }
                    }
                    .frame(height: CGFloat(min(max(sessions.count, sessions.isEmpty ? 0 : 1), IslandLayout.maxRows)) * IslandLayout.rowHeight
                        + (model.detailSessionID != nil ? IslandLayout.detailHeight : 0))
                }
            }

            // Chips on the left, and the way into the full pop-up on the right.
            ListFooter(updater: model.updater, sessionCount: sessions.count)
                .staggered(min(sessions.count, IslandLayout.maxRows) + 1)
        }
        .padding(.horizontal, 12)
    }
}

/// Chips on the left, the way into the pop-up on the right. When an update is waiting, the
/// Visualizer chip shrinks to its icon and the session count steps aside to make room.
private struct ListFooter: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var updater: Updater
    let sessionCount: Int

    var body: some View {
        let updating = UpdateChip.isShowing(updater)
        HStack(spacing: 8) {
                ConnectedAgentsChip()
                UpdateChip(updater: updater)
                ChipButton(action: { model.openVisualizer() }) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                    if !updating { Text("Visualizer") }
                }
                .help("Visualizer")
                Spacer(minLength: 4)
                if sessionCount > IslandLayout.maxRows && !updating {
                    Text("\(sessionCount) sessions")
                        .font(DSFont.sans(11.5, .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                RoundIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open Turbo", size: 34, outlined: true) {
                    model.openPopup(.home)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: IslandLayout.listFooterHeight)
    }
}

/// Quiet and Settings, tucked beside the notch like HeyClicky's.
private struct ListTopBar: View {
    @EnvironmentObject private var model: AppModel
    let geometry: NotchGeometry

    var body: some View {
        HStack(spacing: 2) {
            Text(model.isQuiet ? "Quiet" : summary)
                .font(DSFont.sans(11.5, .semibold))
                .foregroundStyle(model.board.needsYou.isEmpty ? DS.Palette.textTertiary : DS.Palette.gold)
                .lineLimit(1)
                .padding(.leading, 6)
            Spacer(minLength: geometry.docked ? geometry.notchSize.width + 8 : 8)
            RoundIconButton(symbol: model.isQuiet ? "bell.slash.fill" : "bell", help: model.isQuiet ? "Turn alerts back on" : "Quiet for 1 hour", size: 28) {
                model.setQuiet(for: model.isQuiet ? nil : 3600)
            }
            RoundIconButton(symbol: "gearshape.fill", help: "Settings", size: 28) {
                model.openPopup(.settings)
            }
        }
        .padding(.horizontal, 10)
    }

    private var summary: String {
        let board = model.board
        if !board.needsYou.isEmpty { return "\(board.needsYou.count) need\(board.needsYou.count == 1 ? "s" : "") you" }
        if !board.cooking.isEmpty { return "\(board.cooking.count) cooking" }
        return ""
    }
}

/// One row of the hover list: the chat-style row with a hover wash and a hairline above.
private struct IslandChatRow: View {
    @EnvironmentObject private var model: AppModel
    let session: AgentSession
    let now: Date
    let divider: Bool
    @State private var hovering = false

    var body: some View {
        ChatRow(session: session, now: now)
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0))
            )
            .overlay(alignment: .top) {
                if divider && !hovering {
                    Rectangle().fill(Color.white.opacity(0.09)).frame(height: 0.5).padding(.leading, 62).padding(.trailing, 10)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { model.open(session) }
            .contextMenu {
                if model.canOpen(session) { Button("Open") { model.open(session) } }
                if model.pendingApproval(for: session) != nil {
                    Button("Allow") { model.decide(session, allow: true) }
                    Button("Deny") { model.decide(session, allow: false) }
                }
                if model.stopMethod(for: session) != nil { Button("Stop") { model.stop(session) } }
                if !session.phase.isActive { Button("Dismiss") { model.dismiss(session) } }
            }
            .animation(DS.Motion.fast, value: hovering)
    }
}

private extension SessionList {
    func hoverRow(_ session: AgentSession, _ inside: Bool) {
        let id = session.id
        let model = self.model
        guard inside else {
            if model.hoveredRowID == id { model.hoveredRowID = nil }
            return
        }
        model.hoveredRowID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak model] in
            guard let model, model.isHoveringIsland, model.hoveredRowID == id, model.detailSessionID != id else { return }
            withAnimation(DS.Motion.base) { model.detailSessionID = id }
            model.markSeen(session)
        }
    }
}

/// What's going on in one thread: what was asked, the latest from the agent, recent steps,
/// and the actions that matter right now.
private struct SessionDetail: View {
    @EnvironmentObject private var model: AppModel
    let session: AgentSession
    @State private var latest: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let prompt = session.lastPrompt {
                labeled("Asked", prompt)
            }
            if let text = latest ?? Format.snippet(session.summary, limit: 200) {
                labeled(session.phase.isActive ? "Latest" : "Result", text)
            }
            if session.phase == .cooking, let now = session.activityDetail {
                labeled("Now", now)
            }
            if case let .needsInput(message) = session.phase, let message {
                labeled("Needs", message)
            }
            if let error = model.approvalErrors[session.id] {
                Text(error)
                    .font(DSFont.sans(11, .medium))
                    .foregroundStyle(DS.Palette.bad)
                    .lineLimit(2)
            }
            if !session.recentSteps.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(session.recentSteps.suffix(5).enumerated()), id: \.offset) { _, tool in
                        Text(stepLabel(tool))
                            .font(DSFont.sans(10, .bold))
                            .foregroundStyle(Color.white.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    if session.beats > 0 {
                        Text("\(session.beats) updates")
                            .font(DSFont.mono(10))
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }
            }
            if session.lastPrompt == nil && latest == nil && session.summary == nil && session.recentSteps.isEmpty {
                Text(session.agent == .cloud || session.agent == .codexCloud
                     ? "Cloud sessions share only progress, not prompts or replies."
                     : "No details yet.")
                    .font(DSFont.sans(11, .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Spacer()
                if let pending = model.pendingApproval(for: session) {
                    Button("Deny") { model.decide(session, allow: false) }
                        .buttonStyle(BCButtonStyle(variant: .secondary, size: .sm))
                    if let rule = pending.rule {
                        Button("Always Allow") { model.alwaysAllow(session) }
                            .buttonStyle(BCButtonStyle(variant: .secondary, size: .sm))
                            .help("Allows \(rule) in this repo from now on")
                    }
                    Button("Allow") { model.decide(session, allow: true) }
                        .buttonStyle(BCButtonStyle(variant: .primary, size: .sm))
                } else {
                    StopButton(session: session)
                    if model.canOpen(session) {
                        Button("Open") { model.open(session) }
                            .buttonStyle(BCButtonStyle(variant: .secondary, size: .sm))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .clipped()
        .task(id: session.lastActivityAt) {
            // For local Claude Code, read the agent's latest words straight from the transcript.
            guard let path = session.transcriptPath else { return }
            let text = await Task.detached(priority: .utility) { ClaudeTranscript.lastAssistantText(atPath: path, currentTurnOnly: true) }.value
            // A newer activity restarted this task. Its read wins, not this older one.
            guard !Task.isCancelled else { return }
            latest = Format.snippet(text, limit: 200)
        }
    }

    private func labeled(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label.uppercased())
                .font(DSFont.sans(10, .heavy))
                .tracking(0.8)
                .foregroundStyle(DS.Palette.textTertiary)
                .frame(width: 58, alignment: .leading)
            Text(text)
                .font(DSFont.sans(11.5, .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct IslandFooterButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(DSFont.sans(11.5, .semibold))
            }
            .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.6))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(hovering ? nil : DS.Motion.out, value: hovering)
    }
}

// MARK: Idle: the tiny island when nothing's cooking

/// The paw beside the notch: always there, so Turbo always has a home to hover.
private struct IdleIsland: View {
    @EnvironmentObject private var model: AppModel
    let geometry: NotchGeometry

    var body: some View {
        let done = model.unseenDone.count
        HStack(spacing: 0) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))
                // A teal dot: finished sessions you haven't looked at yet.
                .overlay(alignment: .topTrailing) {
                    if done > 0 {
                        Circle().fill(DS.Palette.ok).frame(width: 5, height: 5).offset(x: 4, y: -3)
                    }
                }
                .help(done > 0 ? "\(done) finished, not opened yet" : (model.hotKeyAvailable ? "Turbo · ⌃⌥Space" : "Turbo"))
                .frame(width: geometry.docked ? IslandLayout.idleSideWidth : 28)
            if geometry.docked && geometry.hasNotch {
                Color.clear.frame(width: geometry.notchSize.width)
            } else if !geometry.docked {
                Text("Turbo").font(DSFont.sans(11, .bold)).foregroundStyle(Color.white.opacity(0.8))
            } else {
                Color.clear.frame(width: geometry.notchSize.width)
            }
            // Settings, one click from the tiny island.
            Button {
                model.openPopup(.settings)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: geometry.docked ? IslandLayout.idleSideWidth : 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .frame(height: geometry.docked ? geometry.notchSize.height : IslandLayout.floatingIdleSize.height)
    }
}

/// A row that lights up and shows a chevron under the pointer.
struct HoverRow<Content: View>: View {
    var dark = true
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            content()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(dark ? Color.white.opacity(0.5) : Color.secondary)
                .opacity(hovering ? 1 : 0)
                .offset(x: hovering ? 0 : -4)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(dark ? Color.white.opacity(hovering ? 0.08 : 0) : Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

