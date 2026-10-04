import Foundation

public enum Agent: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case cowork
    /// Claude Code running in a cloud session (claude.ai/code), heard through the relay.
    case cloud

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cowork: return "Cowork"
        case .cloud: return "Claude Code (cloud)"
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
        self.date = date
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
            date: now
        )
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
            case "task_started", "user_message":
                return .event(.promptSubmitted)
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

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
