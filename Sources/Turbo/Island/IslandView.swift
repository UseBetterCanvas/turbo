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
        let size = IslandLayout.size(for: presentation, geometry: geometry, rows: model.sessions.count)
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
            SessionList(sessions: model.board.all)
                .padding(.top, IslandLayout.headroom(geometry) + 6)
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
        let lead = sessions.first
        let waiting = sessions.contains { if case .needsInput = $0.phase { return true } else { return false } }
        let agents = Array(Set(sessions.map(\.agent))).sorted { $0.rawValue < $1.rawValue }

        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                // Leading: what's cooking.
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill((lead?.agent.tint ?? DS.Palette.gold).opacity(glow ? 0.45 : 0))
                            .frame(width: 22, height: 22)
                            .blur(radius: 5)
                        if waiting {
                            AttentionHand(size: 12)
                        } else {
                            CookingFlame(tint: lead?.agent.tint ?? DS.Palette.gold, size: 13)
                                .scaleEffect(glow && !reduceMotion ? 1.18 : 1, anchor: .bottom)
                        }
                    }
                    HStack(spacing: -3) {
                        ForEach(agents, id: \.self) { agent in
                            AgentBadge(agent: agent, size: 15)
                                .background(Circle().fill(.black).padding(-1))
                        }
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
                    if let start = lead?.turnStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let text = Format.clock(context.date.timeIntervalSince(start))
                            Text(text)
                                .font(DSFont.sans(11.5, .bold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.92))
                                .numericTransition()
                                .animation(DS.Motion.slow, value: text)
                        }
                    }
                    if sessions.count > 1 || waiting {
                        let waitingCount = sessions.filter { if case .needsInput = $0.phase { return true } else { return false } }.count
                        Text("\(waiting ? waitingCount : sessions.count)")
                            .font(DSFont.sans(9.5, .heavy).monospacedDigit())
                            .foregroundStyle(.black)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(waiting ? DS.Palette.gold : Color.white.opacity(0.9)))
                            .transition(.scale.combined(with: .opacity))
                            .help(waiting ? "\(waitingCount) waiting on you" : "\(sessions.count) cooking")
                    }
                }
                .frame(width: IslandLayout.compactSideWidth, alignment: .center)
            }
            .frame(height: geometry.docked ? geometry.notchSize.height : IslandLayout.floatingCompactHeight)

            if !waiting && !reduceMotion {
                CookingShimmer(tint: lead?.agent.tint ?? DS.Palette.gold)
                    .padding(.horizontal, geometry.docked ? 12 : 18)
                    .padding(.bottom, 1)
            }
        }
        // Every tool call is a heartbeat.
        .onReceive(model.pulses.filter { $0.kind == .beat || $0.kind == .start }) { _ in
            withAnimation(.easeOut(duration: 0.12)) { glow = true }
            withAnimation(.easeIn(duration: 0.5).delay(0.12)) { glow = false }
        }
    }
}

// MARK: Spotlight: the "it's done" moment

private struct SpotlightCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    let spotlight: Spotlight

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
                        Image(systemName: session.agent.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(session.agent.tint)
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
                    .opacity(hovering ? 0 : 1)
            }

            // Hover affordances: one click to the thread, and a way out.
            HStack(spacing: 6) {
                if session.link != nil || session.hostAppBundleID != nil {
                    Button("Open") {
                        model.open(session)
                        model.advanceSpotlight()
                    }
                    .buttonStyle(BCButtonStyle(variant: spotlight.kind == .needsInput ? .primary : .secondary, size: .sm))
                    .controlSize(.small)
                }
                Button {
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
            .opacity(hovering ? 1 : 0)
            .offset(y: hovering ? 0 : -4)
            .animation(DS.Motion.slow, value: hovering)
        }
        .overlay(alignment: .bottom) {
            if spotlight.kind == .finished {
                CountdownBar(seconds: prefs.celebrateSeconds, tint: session.agent.tint)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 6)
                    .opacity(hovering ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: hovering)
            }
        }
    }

    private func title(for session: AgentSession) -> String {
        switch spotlight.kind {
        case .finished: return session.failed ? "\(session.projectName) failed" : "\(session.projectName) is done"
        case .needsInput: return "\(session.projectName) needs you"
        }
    }

    private func subtitle(for session: AgentSession) -> String {
        if spotlight.kind == .finished, let duration = session.cookDuration {
            return "\(session.agent.displayName) · cooked for \(Format.duration(duration))"
        }
        return session.agent.displayName
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

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 0) {
                    // One line: what's going on right now.
                    Text(headline(for: model.board, now: context.date))
                        .font(DSFont.sans(12, .semibold).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: IslandLayout.listHeadlineHeight)
                    if sessions.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "pawprint.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.white.opacity(0.5))
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Nothing cooking").font(DSFont.sans(12.5, .bold)).foregroundStyle(.white)
                                Text("Start a session and it shows up here.")
                                    .font(DSFont.sans(11, .medium))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: IslandLayout.rowHeight)
                        .staggered(0)
                    }
                    ForEach(Array(sessions.prefix(IslandLayout.maxRows).enumerated()), id: \.element.id) { index, session in
                        HoverRow {
                            SessionRow(session: session, now: context.date)
                        } action: {
                            model.open(session)
                        }
                        .frame(height: IslandLayout.rowHeight)
                        .staggered(index)
                    }
                }
            }

            // Everything else is one click away.
            HStack(spacing: 6) {
                IslandFooterButton(symbol: "rectangle.expand.vertical", title: sessions.count > IslandLayout.maxRows ? "All \(sessions.count) sessions" : "Open Turbo") {
                    model.openPopup(.home)
                }
                Spacer()
                IslandFooterButton(symbol: "sparkles", title: "Visualizer") {
                    model.openVisualizer()
                }
                IslandFooterButton(symbol: "gearshape", title: "Settings") {
                    model.openPopup(.settings)
                }
            }
            .frame(height: IslandLayout.listFooterHeight - 6)
            .padding(.top, 2)
            .staggered(min(sessions.count, IslandLayout.maxRows) + 1)
        }
        .padding(.horizontal, 10)
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
        let done = model.board.done.count
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
                .help(done > 0 ? "\(done) done" : "Turbo")
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

struct SessionRow: View {
    let session: AgentSession
    let now: Date
    var dark = true

    var body: some View {
        HStack(spacing: 10) {
            AgentBadge(agent: session.agent, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName)
                    .font(DSFont.sans(12.5, .bold))
                    .foregroundStyle(dark ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(session.statusText(now: now))
                    .font(DSFont.sans(11, .medium).monospacedDigit())
                    .foregroundStyle(dark ? Color.white.opacity(0.55) : Color.secondary)
                    .lineLimit(1)
                    .numericTransition()
            }
            Spacer(minLength: 0)
            switch session.phase {
            case .cooking:
                CookingFlame(tint: session.agent.tint, size: 12)
            case .needsInput:
                Image(systemName: "hand.raised.fill").foregroundStyle(DS.Palette.gold).font(.system(size: 12))
            case .done:
                Image(systemName: session.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(session.failed ? DS.Palette.bad : DS.Palette.ok)
                    .font(.system(size: 13))
            case .idle:
                EmptyView()
            }
        }
    }
}
