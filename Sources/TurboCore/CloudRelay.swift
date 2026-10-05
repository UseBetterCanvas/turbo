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

    /// Where Turbo posts stop requests for cloud sessions. Same secret as the channel.
    public static func stopChannel(_ channel: String) -> String { channel + "-stop" }

    /// What Turbo posts to ask a cloud session to stop.
    public static func stopMessage(sessionID: String) -> String { "stop " + sessionID }

    /// The hook script that runs inside cloud sessions. Strips the hook payload down to the
    /// safe fields and posts it in the background so tool calls are never slowed down.
    /// Before a tool call it also checks, at most every 5 seconds, whether you pressed Stop.
    /// `shareTitles` also sends the first few words of each prompt, so cloud sessions get a
    /// name instead of just the repo. Off unless you turn it on.
    public static func relayScript(channel: String, server: URL = defaultServer, shareTitles: Bool = false) -> String {
        // Opt-in: the prompt (first 500 characters) and Claude's final reply (first 1,500), read
        // from the session's own transcript when the turn stops. No single quotes: this python
        // runs inside a single-quoted shell string.
        let titleLines = shareTitles ? #"""
        if d.get("hook_event_name") == "UserPromptSubmit":
            out["prompt"] = str(d.get("prompt", "")).strip()[:500]
        if d.get("hook_event_name") == "Stop":
            try:
                with open(str(d.get("transcript_path") or ""), "rb") as fh:
                    fh.seek(0, 2)
                    fh.seek(max(0, fh.tell() - 200000))
                    lines = fh.read().decode("utf-8", "ignore").splitlines()
                for raw in reversed(lines):
                    try:
                        o = json.loads(raw)
                    except Exception:
                        continue
                    if o.get("isSidechain"):
                        continue
                    c0 = (o.get("message") or {}).get("content")
                    if o.get("type") == "user" and not (isinstance(c0, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c0)):
                        break
                    if o.get("type") != "assistant":
                        continue
                    c = (o.get("message") or {}).get("content")
                    t = c if isinstance(c, str) else chr(10).join(b.get("text", "") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text")
                    if t.strip():
                        out["reply"] = t.strip()[:1500]
                        break
            except Exception:
                pass

        """# : ""
        let stopURL = server.appendingPathComponent(stopChannel(channel)).appendingPathComponent("json").absoluteString + "?poll=1&since=10m"
        return """
        #!/bin/bash
        # \(marker): tells the Turbo app on your Mac what this cloud session is doing.
        # Sends the event name, repo folder name, session link and Claude's one-line description
        # of the current step.\(shareTitles ? " Also your prompts and the final replies from Claude (you turned that on)." : "") Never code.
        input=$(cat)
        result=$(printf '%s' "$input" | python3 -c '
        import json, os, sys, time
        d = json.load(sys.stdin)
        out = {k: d[k] for k in ("hook_event_name", "session_id", "tool_name", "notification_type") if k in d}
        if d.get("hook_event_name") == "Notification":
            out["message"] = str(d.get("message", ""))[:200]
        ti = d.get("tool_input") if isinstance(d.get("tool_input"), dict) else {}
        todo = next((t for t in ti.get("todos") or [] if isinstance(t, dict) and t.get("status") == "in_progress"), None)
        act = (todo or {}).get("activeForm") or ti.get("description")
        if act:
            out["activity"] = (str(act).splitlines() or [""])[0][:80]
        \(titleLines)cwd = str(d.get("cwd") or "").rstrip("/")
        out["cwd"] = os.path.basename(cwd) or cwd
        out["remote_session_id"] = os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID", "")
        print(json.dumps(out))
        stop = False
        if d.get("hook_event_name") == "PreToolUse":
            try:
                state = os.path.expanduser("~/.claude/turbo-stop-state")
                seen = open(state).read().split() if os.path.exists(state) else []
                last = float(seen[0]) if seen else 0.0
                if time.time() - last >= 5:
                    import urllib.request
                    body = urllib.request.urlopen("\(stopURL)", timeout=2).read().decode()
                    ids = seen[1:]
                    for line in body.splitlines():
                        m = json.loads(line)
                        if m.get("event") == "message" and m.get("message") == "stop " + str(d.get("session_id", "")) and m.get("id") not in ids:
                            ids.append(m["id"])
                            stop = True
                    open(state, "w").write(" ".join([str(time.time())] + ids[-50:]))
            except Exception:
                pass
        if stop:
            print("STOP")
        ' 2>/dev/null) || exit 0
        payload=$(printf '%s\n' "$result" | head -n 1)
        nohup curl -s -m 5 -d "$payload" "\(publishURL(channel: channel, server: server).absoluteString)" >/dev/null 2>&1 &
        if [ "$(printf '%s\n' "$result" | sed -n 2p)" = "STOP" ]; then
          echo '{"continue":false,"stopReason":"Stopped from Turbo"}'
        fi
        exit 0
        """
    }

    /// Paste into a cloud environment's Setup script. Installs the relay hook for every session
    /// in that environment, and is safe to run repeatedly.
    public static func setupScript(channel: String, server: URL = defaultServer, shareTitles: Bool = false) -> String {
        let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]
        let eventList = events.map { "\"\($0)\"" }.joined(separator: ", ")
        let toolList = toolEvents.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        # --- Turbo: ping your Mac's Dynamic Island when cloud sessions finish ---
        mkdir -p ~/.claude
        cat > ~/.claude/\(marker).sh <<'TURBO_RELAY'
        \(relayScript(channel: channel, server: server, shareTitles: shareTitles))
        TURBO_RELAY
        chmod +x ~/.claude/\(marker).sh
        python3 - <<'TURBO_SETTINGS'
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
        TURBO_SETTINGS
        # --- end Turbo ---
        """
    }
}
