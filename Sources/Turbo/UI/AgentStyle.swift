import TurboCore
import SwiftUI

extension Agent {
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.40, green: 0.74, blue: 1.0)
        case .cowork: return Color(red: 0.70, green: 0.58, blue: 1.0)
        case .cloud: return Color(red: 0.95, green: 0.62, blue: 0.48)
        }
    }

    /// Base hue for the visualizer palette.
    var hue: Double {
        switch self {
        case .claude: return 0.045
        case .codex: return 0.57
        case .cowork: return 0.72
        case .cloud: return 0.04
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cowork: return "folder.fill"
        case .cloud: return "cloud.fill"
        }
    }
}

struct AgentBadge: View {
    let agent: Agent
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(agent.tint.opacity(0.22))
            Image(systemName: agent.symbol)
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(agent.tint)
        }
        .frame(width: size, height: size)
    }
}

/// A flame that flickers while something cooks.
struct CookingFlame: View {
    var tint: Color
    var size: CGFloat = 14
    @State private var flicker = false

    var body: some View {
        Image(systemName: "flame.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .scaleEffect(x: flicker ? 0.92 : 1.05, y: flicker ? 1.08 : 0.94, anchor: .bottom)
            .opacity(flicker ? 0.85 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { flicker = true }
            }
    }
}

extension AgentSession {
    /// "Cooking 1:23", "Needs your OK", "Done 3m ago"
    func statusText(now: Date) -> String {
        switch phase {
        case .cooking:
            return "Cooking " + Format.clock(now.timeIntervalSince(turnStartedAt ?? now))
        case .needsInput:
            return "Needs your OK"
        case .done:
            let ago = now.timeIntervalSince(finishedAt ?? lastActivityAt)
            if let cooked = cookDuration { return "Cooked in \(Format.duration(cooked)) · \(ago < 60 ? "just now" : Format.duration(ago) + " ago")" }
            return ago < 60 ? "Done just now" : "Done \(Format.duration(ago)) ago"
        case .idle:
            return "Idle"
        }
    }
}
