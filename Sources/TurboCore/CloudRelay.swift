import Foundation

/// Cloud sessions (claude.ai/code) run on Anthropic's servers, out of reach of Turbo's local
/// server. So a hook in the cloud container publishes each event to a private channel on a
/// public relay (ntfy.sh), and Turbo subscribes to that channel from the Mac.
///
/// What gets sent is deliberately thin: the event name, session id, tool name, the repo's
/// folder name, permission-prompt text, and the cloud session id (for a clickable link).
/// Prompts, code, tool inputs and Claude's replies never leave the container.
public enum CloudRelay {
    public static let defaultServer = URL(string: "https://ntfy.sh")!
    public static let marker = "turbo-relay"
    static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    /// A fresh unguessable channel name: knowing it is the only way to read or post.
    public static func newChannel() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return "turbo-" + String((0..<24).map { _ in alphabet.randomElement(using: &generator)! })
    }

    public static func subscribeURL(channel: String, since: String?, server: URL = defaultServer) -> URL {
        var components = URLComponents(url: server.appendingPathComponent(channel).appendingPathComponent("json"), resolvingAgainstBaseURL: false)!
        if let since { components.queryItems = [URLQueryItem(name: "since", value: since)] }
        return components.url!
    }

    public static func publishURL(channel: String, server: URL = defaultServer) -> URL {
        server.appendingPathComponent(channel)
    }

    /// The hook script that runs inside cloud sessions. Strips the hook payload down to the
    /// safe fields and posts it in the background so tool calls are never slowed down.
    public static func relayScript(channel: String, server: URL = defaultServer) -> String {
        """
        #!/bin/bash
        # \(marker): tells the Turbo app on your Mac what this cloud session is doing.
        # Sends only the event name, repo folder name and session link. Never prompts, code or output.
        input=$(cat)
        payload=$(printf '%s' "$input" | python3 -c '
        import json, os, sys
        d = json.load(sys.stdin)
        out = {k: d[k] for k in ("hook_event_name", "session_id", "tool_name", "notification_type") if k in d}
        if d.get("hook_event_name") == "Notification":
            out["message"] = str(d.get("message", ""))[:200]
        cwd = str(d.get("cwd") or "").rstrip("/")
        out["cwd"] = os.path.basename(cwd) or cwd
        out["remote_session_id"] = os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID", "")
        print(json.dumps(out))
        ' 2>/dev/null) || exit 0
        nohup curl -s -m 5 -d "$payload" "\(publishURL(channel: channel, server: server).absoluteString)" >/dev/null 2>&1 &
        exit 0
        """
    }

    /// Paste into a cloud environment's Setup script. Installs the relay hook for every session
    /// in that environment, and is safe to run repeatedly.
    public static func setupScript(channel: String, server: URL = defaultServer) -> String {
        let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]
        let eventList = events.map { "\"\($0)\"" }.joined(separator: ", ")
        let toolList = toolEvents.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        # --- Turbo: ping your Mac's Dynamic Island when cloud sessions finish ---
        mkdir -p ~/.claude
        cat > ~/.claude/\(marker).sh <<'CLIPPY_RELAY'
        \(relayScript(channel: channel, server: server))
        CLIPPY_RELAY
        chmod +x ~/.claude/\(marker).sh
        python3 - <<'CLIPPY_SETTINGS'
        import json, os
        path = os.path.expanduser("~/.claude/settings.json")
        try:
            settings = json.load(open(path))
        except Exception:
            settings = {}
        hooks = settings.setdefault("hooks", {})
        for event in [\(eventList)]:
            groups = [g for g in hooks.get(event, []) if "\(marker)" not in json.dumps(g)]
            group = {"hooks": [{"type": "command", "command": "~/.claude/\(marker).sh"}]}
            if event in (\(toolList)):
                group["matcher"] = "*"
            groups.append(group)
            hooks[event] = groups
        json.dump(settings, open(path, "w"), indent=2)
        CLIPPY_SETTINGS
        # --- end Turbo ---
        """
    }
}
