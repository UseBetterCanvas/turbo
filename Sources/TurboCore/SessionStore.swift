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

/// One entry in a session's conversation, as Turbo saw it.
public struct ThreadItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// Something you asked.
        case prompt
        /// What the agent said back.
        case reply
        /// A step it took (the tool's name), with its own description when it gave one.
        case step(tool: String?)
        /// Waiting on you.
        case needs
        /// The turn ended (or failed).
        case finished(failed: Bool)
    }

    public var id: Int
    public var kind: Kind
    public var text: String?
    public var date: Date

    public init(id: Int, kind: Kind, text: String?, date: Date) {
        self.id = id
        self.kind = kind
        self.text = text
        self.date = date
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
    /// The conversation as Turbo saw it: prompts, steps, replies. Newest last, capped.
    public var thread: [ThreadItem] = []
    /// The agent's own words for what it's doing right now, when it gives them.
    public var activityDetail: String?
    /// The latest test run this turn: passed, failed, or none seen.
    public var testsPassed: Bool?
    /// What this turn changed in the repo, when Turbo could tell.
    public var changes: ChangeSummary?
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
        if let tests = event.testsPassed { s.testsPassed = tests }
        if let changes = event.changes { s.changes = changes }
        record(event, in: &s, changes: changes)
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
        Self.attachLateReply(summary, to: &s, at: Date())
        sessions[id] = s
    }

    /// Adds a line to a session's conversation from outside an event (a note you sent).
    public func appendThread(_ kind: ThreadItem.Kind, _ text: String?, to id: String, at date: Date = Date()) {
        guard var s = sessions[id] else { return }
        append(kind, text, to: &s, at: date)
        sessions[id] = s
    }

    /// What a turn changed, worked out after it ended (local sessions read git).
    public func setChanges(_ changes: ChangeSummary, for id: String) {
        guard var s = sessions[id] else { return }
        s.changes = changes
        sessions[id] = s
    }

    public func remove(id: String) {
        sessions[id] = nil
    }

    public func removeAll() {
        sessions.removeAll()
    }

    private static let threadLimit = 80

    /// Adds what just happened to the session's conversation.
    private func record(_ event: AgentEvent, in s: inout AgentSession, changes: [StoreChange]) {
        var item: (ThreadItem.Kind, String?)?
        switch event.kind {
        case .promptSubmitted:
            if let prompt = event.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty,
               !(s.thread.last?.kind == .prompt && s.thread.last?.text == prompt) {
                item = (.prompt, prompt)
            }
        case let .activity(tool):
            // One line per step: the pre and post hooks of the same call collapse.
            guard tool != nil || event.activityDetail != nil else { break }
            if let last = s.thread.last, last.kind == .step(tool: tool), last.text == event.activityDetail { break }
            item = (.step(tool: tool), event.activityDetail)
        case let .needsInput(message):
            if s.thread.last?.kind != .needs || s.thread.last?.text != message { item = (.needs, message) }
        case let .turnComplete(summary), let .turnFailed(summary):
            guard changes.contains(where: { if case .finished = $0 { return true } else { return false } }) else {
                // A late summary for a turn already shown as done: attach it as the reply.
                if let summary { Self.attachLateReply(summary, to: &s, at: event.date) }
                return
            }
            if let summary, !summary.isEmpty { append(.reply, summary, to: &s, at: event.date) }
            if case .turnFailed = event.kind { item = (.finished(failed: true), nil) } else { item = (.finished(failed: false), nil) }
        case .sessionStarted, .sessionEnded:
            break
        }
        if let item { append(item.0, item.1, to: &s, at: event.date) }
    }

    /// A reply that arrives after the turn was marked done goes just before the "done" line.
    static func attachLateReply(_ text: String, to s: inout AgentSession, at date: Date) {
        guard let last = s.thread.last, case .finished = last.kind,
              !s.thread.suffix(4).contains(where: { $0.kind == .reply && $0.text == text }) else { return }
        let id = (s.thread.map(\.id).max() ?? 0) + 1
        s.thread.insert(ThreadItem(id: id, kind: .reply, text: text, date: date), at: s.thread.count - 1)
    }

    private func append(_ kind: ThreadItem.Kind, _ text: String?, to s: inout AgentSession, at date: Date) {
        let id = (s.thread.map(\.id).max() ?? 0) + 1
        s.thread.append(ThreadItem(id: id, kind: kind, text: text, date: date))
        if s.thread.count > Self.threadLimit { s.thread.removeFirst(s.thread.count - Self.threadLimit) }
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
        s.testsPassed = nil
        s.changes = nil
    }

    private func resolveKey(for event: AgentEvent) -> String {
        if let id = event.sessionID { return "\(event.agent.rawValue):\(id)" }
        let mine = sessions.values.filter { $0.agent == event.agent }
        let pick = mine.filter { $0.phase.isActive }.max { $0.lastActivityAt < $1.lastActivityAt }
            ?? mine.max { $0.lastActivityAt < $1.lastActivityAt }
        return pick?.id ?? "\(event.agent.rawValue):\(event.agent.rawValue)"
    }
}
