import Foundation

public enum Agent: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case cowork
    /// Claude Code running in a cloud session (claude.ai/code), heard through the relay.
    case cloud
    /// Codex cloud tasks (chatgpt.com/codex), read with `codex cloud list`.
    case codexCloud

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cowork: return "Cowork"
        case .cloud: return "Claude Code (cloud)"
        case .codexCloud: return "Codex (cloud)"
        }
    }
}

public enum AgentEventKind: Equatable, Sendable {
    /// A session opened but no turn is running yet.
    case sessionStarted
    /// The user sent a prompt: a turn starts cooking.
    case promptSubmitted
    /// Something happened mid-turn (a tool call, a streamed item). Drives the visualizer's beat.
    case activity(tool: String?)
    /// The agent is blocked on the user (permission prompt, question).
    case needsInput(message: String?)
    /// The turn finished.
    case turnComplete(summary: String?)
    /// The turn ended in an error or was cancelled.
    case turnFailed(summary: String?)
    case sessionEnded
}

public struct AgentEvent: Equatable, Sendable {
    public var agent: Agent
    /// nil means "whichever session of this agent is most recently active" — Codex's
    /// notify payload doesn't always carry an id.
    public var sessionID: String?
    public var cwd: String?
    public var kind: AgentEventKind
    public var transcriptPath: String?
    /// Bundle id of the app the agent runs in (Terminal, iTerm, VS Code…), used to jump back to it.
    public var hostAppBundleID: String?
    /// A human name for the session when the agent has one (Cowork task titles).
    public var title: String?
    /// Where clicking the session should take you (a cloud session's page).
    public var link: URL?
    /// What the user asked (local sessions only; cloud pings never include it).
    public var prompt: String?
    /// What the agent says it's doing right now, in its own words: a command's description
    /// ("Wait for Greptile review on PR #8") or the task it's working on.
    public var activityDetail: String?
    /// The session log a local agent is writing (Codex rollouts).
    public var logPath: String?
    public var date: Date

    public init(
        agent: Agent,
        sessionID: String?,
        cwd: String? = nil,
        kind: AgentEventKind,
        transcriptPath: String? = nil,
        hostAppBundleID: String? = nil,
        title: String? = nil,
        link: URL? = nil,
        prompt: String? = nil,
        date: Date = Date()
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
        self.kind = kind
        self.transcriptPath = transcriptPath
        self.hostAppBundleID = hostAppBundleID
        self.title = title
        self.link = link
        self.prompt = prompt
        self.date = date
    }

    func with(logPath: String?) -> AgentEvent {
        var copy = self
        copy.logPath = logPath
        return copy
    }

    func with(activityDetail: String?) -> AgentEvent {
        var copy = self
        copy.activityDetail = activityDetail
        return copy
    }
}

public enum EventParser {
    /// Parses the JSON Claude Code pipes to a hook command on stdin.
    /// https://docs.claude.com/en/docs/claude-code/hooks
    public static func parseClaudeHook(_ data: Data, now: Date = Date()) -> AgentEvent? {
        guard let obj = jsonObject(data), let name = obj["hook_event_name"] as? String else { return nil }

        let kind: AgentEventKind
        switch name {
        case "SessionStart":
            kind = .sessionStarted
        case "UserPromptSubmit":
            kind = .promptSubmitted
        case "PreToolUse", "PostToolUse", "SubagentStop", "PreCompact":
            kind = .activity(tool: obj["tool_name"] as? String)
        case "Notification":
            let message = obj["message"] as? String
            // Claude also nags after ~60s of idling at the prompt. That isn't "needs input"
            // in the cooking sense: the turn is already over.
            if obj["notification_type"] as? String == "idle_prompt"
                || message?.lowercased().contains("waiting for your input") == true {
                return nil
            }
            kind = .needsInput(message: message)
        case "Stop":
            kind = .turnComplete(summary: obj["last_assistant_message"] as? String)
        case "SessionEnd":
            kind = .sessionEnded
        default:
            return nil
        }

        return AgentEvent(
            agent: .claude,
            sessionID: (obj["session_id"] as? String) ?? "claude",
            cwd: obj["cwd"] as? String,
            kind: kind,
            transcriptPath: obj["transcript_path"] as? String,
            prompt: obj["prompt"] as? String,
            date: now
        ).with(activityDetail: activityDetail(from: obj))
    }

    /// The agent's own one-line description of what it's doing. Claude Code writes one for each
    /// command and subagent, and an "active form" for the task in progress on its todo list.
    /// Cloud pings carry it as `activity`.
    static func activityDetail(from obj: [String: Any]) -> String? {
        var text = obj["activity"] as? String
        if text == nil, let input = obj["tool_input"] as? [String: Any] {
            if let todos = input["todos"] as? [[String: Any]],
               let current = todos.first(where: { $0["status"] as? String == "in_progress" }) {
                text = (current["activeForm"] as? String) ?? (current["content"] as? String)
            } else {
                text = input["description"] as? String
            }
        }
        guard let line = text?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// A Claude Code permission prompt, from the `PermissionRequest` hook.
    public struct PermissionAsk: Equatable, Sendable {
        public var sessionID: String
        public var cwd: String?
        public var tool: String
        /// What it wants to do, in one line: the command, the file, or the URL.
        public var detail: String?
        /// False when the detail had to be shortened. Turbo then leaves the prompt to the
        /// terminal, so nobody allows a command they couldn't read in full.
        public var isComplete: Bool = true
        /// A permission rule that allows exactly this request from now on, when one is safe to
        /// offer: `Bash(npm test)` for a one-line command.
        public var rule: String? = nil
    }

    public static func parsePermissionRequest(_ data: Data) -> PermissionAsk? {
        guard let obj = jsonObject(data), let tool = obj["tool_name"] as? String else { return nil }
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let raw = (input["command"] as? String)
            ?? (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? (input["url"] as? String)
            ?? (input["pattern"] as? String)
            ?? (input["description"] as? String)
        let full = raw.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        let limit = 100
        let detail = full.map { $0.count > limit ? String($0.prefix(limit - 1)) + "…" : $0 }
        return PermissionAsk(
            sessionID: (obj["session_id"] as? String) ?? "claude", cwd: obj["cwd"] as? String, tool: tool, detail: detail,
            isComplete: (full?.count ?? 0) <= limit,
            rule: allowRule(tool: tool, input: input)
        )
    }

    static func allowRule(tool: String, input: [String: Any]) -> String? {
        guard tool == "Bash", let command = (input["command"] as? String)?.trimmingCharacters(in: .whitespaces),
              !command.isEmpty, command.count <= 100, !command.contains(where: \.isNewline),
              !command.contains("(") && !command.contains(")") else { return nil }
        return "Bash(\(command))"
    }

    /// Denies the request and stops Claude's turn.
    public static let permissionStop = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Stopped from Turbo","interrupt":true}}}"#

    /// The JSON a PermissionRequest hook prints to allow or deny.
    public static func permissionDecision(allow: Bool) -> String {
        allow
            ? #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            : #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Turbo"}}}"#
    }

    /// Parses the JSON Codex passes as the last argv element to its `notify` program.
    public static func parseCodexNotify(_ data: Data, now: Date = Date()) -> AgentEvent? {
        guard let obj = jsonObject(data), obj["type"] as? String == "agent-turn-complete" else { return nil }
        let id = (obj["thread-id"] as? String) ?? (obj["session-id"] as? String) ?? (obj["conversation-id"] as? String)
        return AgentEvent(
            agent: .codex,
            sessionID: id,
            cwd: obj["cwd"] as? String,
            kind: .turnComplete(summary: obj["last-assistant-message"] as? String),
            date: now
        )
    }

    public enum RolloutLine: Equatable {
        case meta(id: String?, cwd: String?)
        case event(AgentEventKind)
        /// Something the person typed. Starts a turn and can name the session.
        case prompt(String?)
    }

    /// Parses one line of a Codex rollout file (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl).
    /// The format isn't a public contract, so this only recognizes a handful of
    /// well-known markers and ignores everything else.
    public static func parseCodexRolloutLine(_ line: Data) -> RolloutLine? {
        guard let obj = jsonObject(line) else { return nil }
        let type = obj["type"] as? String
        let payload = obj["payload"] as? [String: Any] ?? [:]

        switch type {
        case "session_meta":
            return .meta(id: payload["id"] as? String, cwd: payload["cwd"] as? String)
        case "turn_context":
            if let cwd = payload["cwd"] as? String { return .meta(id: nil, cwd: cwd) }
            return nil
        case "event_msg":
            switch payload["type"] as? String {
            case "task_started":
                return .event(.promptSubmitted)
            case "user_message":
                return .prompt(payload["message"] as? String)
            case "task_complete":
                return .event(.turnComplete(summary: payload["last_agent_message"] as? String))
            case "exec_command_begin", "mcp_tool_call_begin", "patch_apply_begin", "web_search_begin":
                return .event(.activity(tool: payload["type"] as? String))
            case "agent_message", "agent_reasoning":
                return .event(.activity(tool: nil))
            default:
                return nil
            }
        case "response_item":
            switch payload["type"] as? String {
            case "function_call", "custom_tool_call", "local_shell_call":
                return .event(.activity(tool: payload["name"] as? String))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Parses one line of a Cowork session's audit log
    /// (~/Library/Application Support/Claude/local-agent-mode-sessions/…/local_<id>/audit.jsonl).
    /// The lines mirror the Claude Agent SDK's message stream: `user` prompts, `assistant`
    /// turns, and a `result` at the end of every turn. Not a public contract, so stay tolerant.
    public static func parseCoworkAuditLine(_ line: Data) -> RolloutLine? {
        guard let obj = jsonObject(line) else { return nil }
        if obj["isSynthetic"] as? Bool == true || obj["isMeta"] as? Bool == true { return nil }
        let message = obj["message"] as? [String: Any]
        let blocks = message?["content"] as? [[String: Any]] ?? []
        let blockTypes = Set(blocks.compactMap { $0["type"] as? String })

        switch obj["type"] as? String {
        case "system":
            guard obj["subtype"] as? String == "init" else { return nil }
            return .meta(id: nil, cwd: obj["cwd"] as? String)
        case "user":
            guard message != nil else { return nil }
            // Tool results and subagent traffic come back as "user" lines too.
            if blockTypes.contains("tool_result") || obj["parent_tool_use_id"] is String {
                return .event(.activity(tool: nil))
            }
            return .event(.promptSubmitted)
        case "assistant":
            let tool = blocks.first { $0["type"] as? String == "tool_use" }?["name"] as? String
            return .event(.activity(tool: tool))
        case "tool_use_summary":
            return .event(.activity(tool: nil))
        case "result":
            if obj["parent_tool_use_id"] is String { return .event(.activity(tool: nil)) }
            return .event(.turnComplete(summary: obj["result"] as? String))
        default:
            return nil
        }
    }

    /// One line of an ntfy JSON stream (`GET https://ntfy.sh/<channel>/json`) carrying a cloud
    /// session's hook event, as sent by `HookInstaller.relayScript`. Returns the ntfy message id
    /// (for resuming the stream) along with the event.
    public static func parseRelayLine(_ line: Data, now: Date = Date()) -> (id: String, event: AgentEvent?)? {
        guard let envelope = jsonObject(line), envelope["event"] as? String == "message",
              let id = envelope["id"] as? String else { return nil }
        guard let message = envelope["message"] as? String,
              let payload = message.data(using: .utf8),
              var event = parseClaudeHook(payload, now: now) else { return (id, nil) }
        event.agent = .cloud
        let remote = (jsonObject(payload)?["remote_session_id"] as? String) ?? ""
        if remote.hasPrefix("cse_") {
            event.link = URL(string: "https://claude.ai/code/session_" + remote.dropFirst(4))
        }
        return (id, event)
    }

    public static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
