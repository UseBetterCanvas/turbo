import SwiftUI
import TurboCore

extension Agent {
    /// Cloud sessions share their agent's mark and add a small cloud badge.
    var isCloud: Bool { self == .cloud || self == .codexCloud }
}

/// Claude's mark: a spark of tapered rays.
struct SparkShape: Shape {
    var rays = 8

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.16
        let half = Double.pi / Double(rays) * 0.42
        var path = Path()
        for i in 0..<rays {
            let a = Double(i) / Double(rays) * 2 * .pi - .pi / 2
            // Alternate long and short rays, like a hand-drawn spark.
            let r = i.isMultiple(of: 2) ? outer : outer * 0.78
            func p(_ angle: Double, _ radius: CGFloat) -> CGPoint {
                CGPoint(x: c.x + CGFloat(cos(angle)) * radius, y: c.y + CGFloat(sin(angle)) * radius)
            }
            path.move(to: p(a - half, inner))
            path.addQuadCurve(to: p(a, r), control: p(a - half * 0.35, r * 0.6))
            path.addQuadCurve(to: p(a + half, inner), control: p(a + half * 0.35, r * 0.6))
            path.closeSubpath()
        }
        path.addEllipse(in: CGRect(x: c.x - inner * 1.4, y: c.y - inner * 1.4, width: inner * 2.8, height: inner * 2.8))
        return path
    }
}

/// The agent's mark on its own, in its color.
struct AgentGlyph: View {
    let agent: Agent
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch agent {
            case .claude, .cloud:
                SparkShape().fill(agent.tint).frame(width: size, height: size)
            case .codex, .codexCloud:
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: size * 0.82, weight: .bold))
                    .foregroundStyle(agent.tint)
            case .cowork:
                Image(systemName: "folder.fill")
                    .font(.system(size: size * 0.86, weight: .semibold))
                    .foregroundStyle(agent.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.displayName)
    }
}

/// A session at a glance: whose it is (the mark), where it runs (a cloud badge), and what
/// it needs (a ring while cooking, a gold dot when it's waiting, a check or ✕ when done).
struct SessionIcon: View {
    @EnvironmentObject private var model: AppModel
    let session: AgentSession
    var size: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A round, soft avatar in the agent's color, like a contact photo.
        ZStack {
            Circle().fill(DS.Palette.overlay)
            Circle().fill(session.agent.tint.opacity(0.26))
            Circle().strokeBorder(session.agent.tint.opacity(0.55), lineWidth: max(1.5, size * 0.05))
            AgentGlyph(agent: session.agent, size: size * 0.46)
        }
        .frame(width: size, height: size)
        .overlay { ring }
        .overlay(alignment: .topLeading) {
            if session.agent.isCloud {
                badge(symbol: "cloud.fill", fill: DS.Palette.card, tint: DS.Palette.textSecondary)
                    .offset(x: -size * 0.06, y: -size * 0.06)
                    .help("Runs in the cloud")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            status.offset(x: size * 0.06, y: size * 0.06)
        }
    }

    /// A slow arc that circles the avatar while the session cooks.
    @ViewBuilder private var ring: some View {
        if model.stopping.contains(session.id) {
            // Stop pressed: a dashed red ring until it lands.
            Circle().strokeBorder(DS.Palette.bad, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).padding(-3)
        } else if session.phase == .cooking {
            if reduceMotion {
                Circle().strokeBorder(DS.Palette.textSecondary.opacity(0.6), lineWidth: 1.5).padding(-3)
            } else {
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(DS.Palette.textPrimary.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360))
                        .padding(-3)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch session.phase {
        case .needsInput:
            badge(symbol: "exclamationmark", fill: DS.Palette.gold, tint: .black)
        case .done:
            if session.failed {
                badge(symbol: "xmark", fill: DS.Palette.bad, tint: .white)
            } else {
                badge(symbol: "checkmark", fill: DS.Palette.ok, tint: .black)
            }
        case .cooking, .idle:
            EmptyView()
        }
    }

    private func badge(symbol: String, fill: Color, tint: Color) -> some View {
        let d = max(12, size * 0.36)
        return Image(systemName: symbol)
            .font(.system(size: d * 0.52, weight: .heavy))
            .foregroundStyle(tint)
            .frame(width: d, height: d)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
    }
}

/// Stop for an active session: one click, then "Stopping…" until it lands (click again to take it back).
struct StopButton: View {
    @EnvironmentObject private var model: AppModel
    let session: AgentSession

    var body: some View {
        if session.phase.isActive, let method = model.stopMethod(for: session) {
            let stopping = model.stopping.contains(session.id)
            Button {
                if stopping { model.cancelStop(session) } else { model.stop(session) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: stopping ? "hourglass" : "stop.fill").font(.system(size: 9, weight: .bold))
                    Text(stopping ? "Stopping…" : "Stop")
                }
            }
            .buttonStyle(BCButtonStyle(variant: .secondary, size: .sm))
            .help(stopping ? "Click to keep it going instead" : Self.help(method))
        }
    }

    static func help(_ method: AppModel.StopMethod) -> String {
        switch method {
        case .nextStep: return "Stops Claude before its next step"
        case .interrupt: return "Ends this Codex run. Pick it up again with codex resume"
        case .cloud: return "Stops the cloud session within a few seconds of its next step"
        }
    }
}
