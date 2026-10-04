import Foundation

public enum SessionPhase: Equatable, Sendable {
    case idle
    case cooking
    case needsInput(message: String?)
    case done(summary: String?)

    public var isActive: Bool {
        switch self {
        case .cooking, .needsInput: return true
        case .idle, .done: return false
        }
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public var id: String { "\(agent.rawValue):\(sessionID)" }
    public let agent: Agent
    public let sessionID: String
    public var cwd: String?
    public var phase: SessionPhase = .idle
    public var turnStartedAt: Date?
    public var finishedAt: Date?
    public var lastActivityAt: Date
    /// Activity events seen in the current turn.
    public var beats: Int = 0
    public var lastTool: String?
    public var transcriptPath: String?
    /// The log file a local agent writes (Codex), used to find its process.
    public var logPath: String?
    public var hostAppBundleID: String?
    public var title: String?
    public var link: URL?
    /// The last turn ended in an error or was cancelled (shown as failed, not done).
    public var failed = false
    /// What was asked to start this turn (local sessions only).
    public var lastPrompt: String?
    /// The agent's own words for what it's doing right now, when it gives them.
    public var activityDetail: String?
    /// When it started waiting on you. Nil unless it's waiting.
    public var needsInputSince: Date?
    /// A short name from the first thing this session was asked. Kept across turns.
    public var threadName: String?
    /// The latest steps this turn, newest last (tool names).
    public var recentSteps: [String] = []

    public init(agent: Agent, sessionID: String, cwd: String? = nil, lastActivityAt: Date) {
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
        self.lastActivityAt = lastActivityAt
    }

    /// What to call this session: its title, a name from its first prompt, or its repo.
    public var projectName: String {
        if let title, !title.isEmpty { return title }
        return threadName ?? repoName ?? agent.displayName
    }

    /// The folder it runs in, unless that's an opaque id.
    public var repoName: String? { SessionNaming.repoName(fromPath: cwd) }

    /// The repo, when the name doesn't already say it. Shown next to the status.
    public var place: String? {
        guard let repo = repoName, repo != projectName else { return nil }
        return repo
    }

    public var summary: String? {
        if case let .done(summary) = phase { return summary }
        return nil
    }

    /// How long the last finished turn took, when we saw it start.
    public var cookDuration: TimeInterval? {
        guard let start = turnStartedAt, let end = finishedAt else { return nil }
        return max(0, end.timeIntervalSince(start))
    }
}

public enum StoreChange: Equatable, Sendable {
    case started(AgentSession)
    case beat(AgentSession)
    case needsInput(AgentSession)
    case resumed(AgentSession)
    case finished(AgentSession)
    case removed(id: String)
}

/// The cooking state machine. Not thread-safe: drive it from one queue (the main actor in the app).
public final class SessionStore {
    public private(set) var sessions: [String: AgentSession] = [:]

    /// Activity or a duplicate "done" arriving this soon after a turn finished belongs to that
    /// turn (Codex can report completion via both notify and its rollout file).
    public var doneGrace: TimeInterval = 4
    /// An active session that's been silent this long is assumed dead (killed terminal, crash).
    public var staleAfter: TimeInterval = 20 * 60
    /// Finished sessions linger in the "recent" list for this long.
    public var keepDoneFor: TimeInterval = 30 * 60

    public init() {}

    public var sorted: [AgentSession] {
        sessions.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    public var active: [AgentSession] {
        sessions.values.filter { $0.phase.isActive }.sorted { ($0.turnStartedAt ?? .distantPast) < ($1.turnStartedAt ?? .distantPast) }
    }

    @discardableResult
    public func apply(_ event: AgentEvent) -> [StoreChange] {
        let now = event.date
        let key = resolveKey(for: event)
        let isNew = sessions[key] == nil
        let sessionID = event.sessionID ?? sessions[key]?.sessionID ?? event.agent.rawValue
        var s = sessions[key] ?? AgentSession(agent: event.agent, sessionID: sessionID, lastActivityAt: now)

        if let cwd = event.cwd, !cwd.isEmpty { s.cwd = cwd }
        if let path = event.transcriptPath { s.transcriptPath = path }
        if let path = event.logPath { s.logPath = path }
        if let host = event.hostAppBundleID, !host.isEmpty { s.hostAppBundleID = host }
        if let title = event.title, !title.isEmpty { s.title = title }
        if let link = event.link { s.link = link }

        var changes: [StoreChange] = []

        switch event.kind {
        case .sessionStarted:
            if isNew { s.lastActivityAt = now }

        case .promptSubmitted:
            s.lastActivityAt = now
            if !s.phase.isActive {
                startTurn(&s, at: now)
                changes.append(.started(s))
            }
            if let prompt = event.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                s.lastPrompt = prompt
                if s.threadName == nil { s.threadName = SessionNaming.title(fromPrompt: prompt) }
            }

        case let .activity(tool):
            s.lastActivityAt = now
            if let tool {
                s.lastTool = tool
                // Pre and Post hooks both report a tool; keep one entry per step.
                if s.recentSteps.last != tool || s.phase != .cooking { s.recentSteps.append(tool) }
                if s.recentSteps.count > 6 { s.recentSteps.removeFirst(s.recentSteps.count - 6) }
            }
            switch s.phase {
            case .cooking:
                s.beats += 1
                changes.append(.beat(s))
            case .needsInput:
                s.phase = .cooking
                s.beats += 1
                changes.append(.resumed(s))
            case .idle:
                // We missed the prompt (app launched mid-turn, or the agent doesn't report it).
                startTurn(&s, at: now)
                changes.append(.started(s))
            case .done:
                if let finished = s.finishedAt, now.timeIntervalSince(finished) < doneGrace { break }
                startTurn(&s, at: now)
                changes.append(.started(s))
            }

        case let .needsInput(message):
            s.lastActivityAt = now
            if !s.phase.isActive { startTurn(&s, at: now) }
            if case .needsInput = s.phase {} else { s.needsInputSince = now }
            s.phase = .needsInput(message: message)
            changes.append(.needsInput(s))

        case let .turnComplete(summary), let .turnFailed(summary):
            s.lastActivityAt = now
            let failed: Bool
            if case .turnFailed = event.kind { failed = true } else { failed = false }
            if case let .done(existing) = s.phase, let finished = s.finishedAt, now.timeIntervalSince(finished) < doneGrace {
                // Duplicate report of the same turn; just fill in a summary if we didn't have one.
                if existing == nil, let summary { s.phase = .done(summary: summary) }
                if failed { s.failed = true }
            } else {
                if !s.phase.isActive { s.turnStartedAt = nil }
                s.phase = .done(summary: summary)
                s.finishedAt = now
                s.failed = failed
                changes.append(.finished(s))
            }

        case .sessionEnded:
            sessions[key] = nil
            return isNew ? [] : [.removed(id: key)]
        }

        if case .needsInput = s.phase {} else { s.needsInputSince = nil }
        // After any turn start above, which clears it.
        if case .activity = event.kind, let detail = event.activityDetail { s.activityDetail = detail }
        sessions[key] = s
        return changes
    }

    /// Drops sessions that went silent mid-turn and old finished ones.
    @discardableResult
    public func prune(now: Date = Date()) -> [StoreChange] {
        var changes: [StoreChange] = []
        for (key, s) in sessions {
            let silentFor = now.timeIntervalSince(s.lastActivityAt)
            let expired: Bool
            switch s.phase {
            case .cooking: expired = silentFor > staleAfter
            case .needsInput: expired = silentFor > staleAfter * 3
            case .done, .idle: expired = silentFor > keepDoneFor
            }
            if expired {
                sessions[key] = nil
                changes.append(.removed(id: key))
            }
        }
        return changes
    }

    /// Fills in a finished turn's summary after the fact (e.g. read from Claude's transcript).
    public func setSummary(_ summary: String, for id: String) {
        guard var s = sessions[id], case .done(nil) = s.phase else { return }
        s.phase = .done(summary: summary)
        sessions[id] = s
    }

    public func remove(id: String) {
        sessions[id] = nil
    }

    public func removeAll() {
        sessions.removeAll()
    }

    private func startTurn(_ s: inout AgentSession, at now: Date) {
        s.phase = .cooking
        s.turnStartedAt = now
        s.finishedAt = nil
        s.beats = 0
        s.lastTool = nil
        s.failed = false
        s.recentSteps = []
        s.lastPrompt = nil
        s.activityDetail = nil
    }

    private func resolveKey(for event: AgentEvent) -> String {
        if let id = event.sessionID { return "\(event.agent.rawValue):\(id)" }
        let mine = sessions.values.filter { $0.agent == event.agent }
        let pick = mine.filter { $0.phase.isActive }.max { $0.lastActivityAt < $1.lastActivityAt }
            ?? mine.max { $0.lastActivityAt < $1.lastActivityAt }
        return pick?.id ?? "\(event.agent.rawValue):\(event.agent.rawValue)"
    }
}
