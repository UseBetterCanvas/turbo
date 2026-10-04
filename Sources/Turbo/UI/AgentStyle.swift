import TurboCore
import SwiftUI

extension Agent {
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.40, green: 0.74, blue: 1.0)
        case .cowork: return Color(red: 0.70, green: 0.58, blue: 1.0)
        case .cloud: return Color(red: 0.95, green: 0.62, blue: 0.48)
        case .codexCloud: return Color(red: 0.47, green: 0.77, blue: 1.0)
        }
    }

    /// Base hue for the visualizer palette.
    var hue: Double {
        switch self {
        case .claude: return 0.045
        case .codex: return 0.57
        case .cowork: return 0.72
        case .cloud: return 0.04
        case .codexCloud: return 0.57
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cowork: return "folder.fill"
        case .cloud: return "cloud.fill"
        case .codexCloud: return "icloud.fill"
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
            return "\(activity) · " + Format.clock(now.timeIntervalSince(turnStartedAt ?? now))
        case let .needsInput(message):
            return message.map { "Needs your OK: \($0)" } ?? "Needs your OK"
        case .done:
            let ago = now.timeIntervalSince(finishedAt ?? lastActivityAt)
            let when = ago < 60 ? "just now" : Format.duration(ago) + " ago"
            if failed { return "Failed \(when)" }
            if let summary = Format.snippet(summary, limit: 70) { return "Done \(when) · \(summary)" }
            if let cooked = cookDuration { return "Cooked in \(Format.duration(cooked)) · \(when)" }
            return "Done \(when)"
        case .idle:
            return "Idle"
        }
    }

    /// What the agent is doing right now, in plain words, from its latest tool call.
    var activity: String {
        guard let tool = lastTool?.lowercased() else { return "Working" }
        func has(_ words: [String]) -> Bool { words.contains { tool.contains($0) } }
        if has(["bash", "shell", "exec", "command", "terminal"]) { return "Running a command" }
        if has(["edit", "write", "patch", "notebook"]) { return "Editing files" }
        if has(["read", "grep", "glob", "search_files", "ls"]) { return "Reading code" }
        if has(["web", "fetch", "search"]) { return "Searching the web" }
        if has(["task", "agent"]) { return "Working with a helper" }
        if has(["todo", "plan"]) { return "Planning" }
        if has(["mcp"]) { return "Using a connected tool" }
        return "Working"
    }
}

/// One line for the top of the hover list: what's going on across every session.
func headline(for board: SessionBoard, now: Date) -> String {
    var parts: [String] = []
    if !board.needsYou.isEmpty { parts.append("\(board.needsYou.count) need\(board.needsYou.count == 1 ? "s" : "") you") }
    if !board.cooking.isEmpty { parts.append("\(board.cooking.count) cooking") }
    if let latest = board.done.first, let finished = latest.finishedAt, now.timeIntervalSince(finished) < 600 {
        let ago = now.timeIntervalSince(finished)
        parts.append("\(latest.projectName) \(latest.failed ? "failed" : "finished") \(ago < 60 ? "just now" : Format.duration(ago) + " ago")")
    } else if !board.done.isEmpty && parts.isEmpty {
        parts.append("\(board.done.count) done")
    }
    return parts.isEmpty ? "Nothing cooking right now" : parts.joined(separator: " · ")
}
