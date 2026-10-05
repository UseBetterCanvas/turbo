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
    /// `source` tags where the session runs ("cowork" for the Cowork plugin), so the Mac shows it
    /// as the right kind of session.
    public static func relayScript(channel: String, server: URL = defaultServer, shareTitles: Bool = false, source: String? = nil) -> String {
        // Opt-in: the prompt (first 500 characters) and Claude's final reply (first 1,500), read
        // from the session's own transcript when the turn stops. No single quotes: this python
        // runs inside a single-quoted shell string.
        let titleLines = shareTitles ? #"""
        if d.get("hook_event_name") == "UserPromptSubmit":
            out["prompt"] = str(d.get("prompt", "")).strip()[:500]
        pending_imgs = []
        if d.get("hook_event_name") == "Stop":
            try:
                with open(str(d.get("transcript_path") or ""), "rb") as fh:
                    fh.seek(0, 2)
                    # Big enough for a prompt record carrying a few full-size screenshots.
                    fh.seek(max(0, fh.tell() - 24000000))
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
                        # The prompt that started this turn: its pasted images go up after the Stop check.
                        for b in (c0 if isinstance(c0, list) else []):
                            src = b.get("source") if isinstance(b, dict) and b.get("type") == "image" else None
                            if isinstance(src, dict) and src.get("type") == "base64" and len(pending_imgs) < 3:
                                ext = {"image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"}.get(src.get("media_type"), "png")
                                pending_imgs.append((str(src.get("data") or ""), ext))
                        break
                    if o.get("type") != "assistant" or "reply" in out:
                        continue
                    c = (o.get("message") or {}).get("content")
                    t = c if isinstance(c, str) else chr(10).join(b.get("text", "") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text")
                    if t.strip():
                        out["reply"] = t.strip()[:1500]
            except Exception:
                pass

        """# : ""
        let stopURL = server.appendingPathComponent(stopChannel(channel)).appendingPathComponent("json").absoluteString + "?poll=1&since=10m"
        let publish = publishURL(channel: channel, server: server).absoluteString
        let sourceLine = source.map { "out[\"source\"] = \"\($0)\"\n" } ?? ""
        let sharePaths = shareTitles ? "            out[\"changes\"][\"paths\"] = paths[:8]\n" : ""
        // Uploads run in parallel with a 4 second budget, after the Stop and reply check, so a slow
        // file server never holds up the session for long.
        let imageLines = shareTitles ? #"""
        if pending_imgs:
            import base64, threading, urllib.request
            links = [None] * len(pending_imgs)
            def upload(i, data, ext):
                try:
                    img = base64.b64decode(data)
                    if len(img) <= 5000000:
                        req = urllib.request.Request("TURBO_FILES_URL", data=img, method="PUT", headers={"Filename": "image-" + str(i + 1) + "." + ext})
                        links[i] = (json.loads(urllib.request.urlopen(req, timeout=4).read().decode()).get("attachment") or {}).get("url")
                except Exception:
                    pass
            workers = [threading.Thread(target=upload, args=(i, data, ext), daemon=True) for i, (data, ext) in enumerate(pending_imgs)]
            for w in workers:
                w.start()
            deadline = time.time() + 4
            for w in workers:
                w.join(max(0, deadline - time.time()))
            if any(links):
                out["prompt_images"] = [x for x in links if x]

        """#.replacingOccurrences(of: "TURBO_FILES_URL", with: filesURL(channel: channel, server: server).absoluteString) : ""
        let note = shareTitles ? " Also your prompts, images you paste in them and the final replies from Claude (you turned that on)." : ""
        return #"""
        #!/bin/bash
        # \#(marker): tells the Turbo app on your Mac what this cloud session is doing.
        # Sends the event name, repo folder name, session link, Claude's one-line description of
        # the current step, test results and how many lines changed.\#(note) Never code.
        # It also picks up replies and Stop requests you send from Turbo.
        input=$(cat)
        result=$(printf '%s' "$input" | python3 -c '
        import json, os, sys, time, subprocess
        d = json.load(sys.stdin)
        out = {k: d[k] for k in ("hook_event_name", "session_id", "tool_name", "notification_type") if k in d}
        ev = d.get("hook_event_name")
        sid = str(d.get("session_id", ""))
        if ev == "Notification":
            out["message"] = str(d.get("message", ""))[:200]
        ti = d.get("tool_input") if isinstance(d.get("tool_input"), dict) else {}
        todo = next((t for t in ti.get("todos") or [] if isinstance(t, dict) and t.get("status") == "in_progress"), None)
        act = (todo or {}).get("activeForm") or ti.get("description")
        if act:
            out["activity"] = (str(act).splitlines() or [""])[0][:80]
        \#(titleLines)cwd = str(d.get("cwd") or "").rstrip("/")
        full = cwd
        out["cwd"] = os.path.basename(cwd) or cwd
        out["remote_session_id"] = os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID", "")
        \#(sourceLine)tr = d.get("tool_response")
        if ev == "PostToolUse" and isinstance(ti.get("command"), str):
            cmd = ti["command"].lower()
            runners = ("npm test", "npm run test", "pnpm test", "yarn test", "bun test", "jest", "vitest", "pytest", "go test", "cargo test", "swift test", "xcodebuild test", "rspec", "rails test", "mix test", "phpunit", "gradle test", "gradlew test", "mvn test", "dotnet test", "make test", "deno test", "playwright test")
            if any(r in cmd for r in runners) and not (isinstance(tr, dict) and tr.get("interrupted")):
                txt = ""
                code = None
                if isinstance(tr, dict):
                    txt = chr(10).join(str(tr.get(k) or "") for k in ("stdout", "stderr", "output")).lower()
                    code = tr.get("exit_code", tr.get("exitCode"))
                elif isinstance(tr, str):
                    txt = tr.lower()
                ok = None
                if isinstance(code, int):
                    ok = code == 0
                elif txt.strip():
                    import re
                    fails = [int(n) for n in re.findall(r"(\d+)\s+(?:failed|failing|failures?|errors?)\b", txt) + re.findall(r"(?:failed|failures|errors):\s*(\d+)", txt)]
                    lines = [x.strip() for x in txt.splitlines()]
                    if any(n > 0 for n in fails) or any(x.startswith(("fail ", "fail:", "--- fail")) or "test result: failed" in x or "tests failed" in x for x in lines):
                        ok = False
                    elif any(int(n) > 0 for n in re.findall(r"(\d+)\s+(?:passed|passing)\b", txt)) or "test result: ok" in txt or "all tests passed" in txt or 0 in fails:
                        ok = True
                if ok is not None:
                    out["tests"] = "pass" if ok else "fail"
        base_file = os.path.expanduser("~/.claude/turbo-base-" + "".join(ch for ch in sid if ch.isalnum() or ch == "-"))
        def git(*args):
            return subprocess.run(["git", "-C", full] + list(args), capture_output=True, text=True, timeout=5).stdout
        def snapshot(base):
            # Per-file line counts against the turn start, plus files git does not track yet.
            files = {}
            for row in git("diff", "--numstat", base).splitlines():
                p = row.split(chr(9), 2)
                if len(p) == 3:
                    files[p[2]] = [int(p[0]) if p[0].isdigit() else 0, int(p[1]) if p[1].isdigit() else 0]
            for path in git("ls-files", "--others", "--exclude-standard").splitlines()[:200]:
                if path in files:
                    continue
                n = 0
                try:
                    fp = os.path.join(full, path)
                    if os.path.getsize(fp) < 1000000:
                        n = open(fp, "rb").read().count(b"\n")
                except Exception:
                    pass
                files[path] = [n, 0]
            return files
        if ev == "UserPromptSubmit":
            start = {"head": "", "files": {}}
            try:
                if full:
                    start["head"] = git("rev-parse", "HEAD").strip()
                    start["files"] = snapshot(start["head"] or "HEAD")
            except Exception:
                pass
            try:
                open(base_file, "w").write(json.dumps(start))
            except Exception:
                pass
        if ev == "Stop" and full:
            try:
                start = json.load(open(base_file)) if os.path.exists(base_file) else {}
                before = start.get("files") or {}
                now = snapshot(start.get("head") or "HEAD")
                add = dele = 0
                paths = []
                for path, cnt in sorted(now.items()):
                    if before.get(path) != cnt:
                        was = before.get(path) or [0, 0]
                        add += max(0, cnt[0] - was[0])
                        dele += max(0, cnt[1] - was[1])
                        paths.append(path)
                paths += [path for path in before if path not in now]
                if paths:
                    out["changes"] = {"files": len(paths), "add": add, "del": dele}
        \#(sharePaths)    except Exception:
                pass
        ctl = ""
        if ev in ("PreToolUse", "Stop"):
            try:
                state = os.path.expanduser("~/.claude/turbo-stop-state")
                seen = open(state).read().split() if os.path.exists(state) else []
                last = float(seen[0]) if seen else 0.0
                if ev == "Stop" or time.time() - last >= 5:
                    import urllib.request
                    body = urllib.request.urlopen("\#(stopURL)", timeout=2).read().decode()
                    ids = seen[1:]
                    turn_start = os.path.getmtime(base_file) if os.path.exists(base_file) else 0
                    msgs = []
                    for line in body.splitlines():
                        m = json.loads(line)
                        if m.get("event") == "message" and m.get("id") not in ids:
                            msgs.append(m)
                    def parsed(m):
                        try:
                            r = json.loads(str(m.get("message", "")))
                            return r if isinstance(r, dict) else {}
                        except Exception:
                            return {}
                    stop_now = any(str(m.get("message", "")) == "stop " + sid for m in msgs)
                    if stop_now:
                        # Stop always wins, even over a waiting reply.
                        ids += [m["id"] for m in msgs if str(m.get("message", "")) == "stop " + sid]
                        ctl = "STOP"
                    elif ev == "Stop":
                        cancelled = set(parsed(m).get("r") for m in msgs if parsed(m).get("t") == "cancel" and parsed(m).get("s") == sid)
                        for m in msgs:
                            r = parsed(m)
                            # Only replies sent during this turn: an old one never surprises a later turn.
                            if r.get("t") == "reply" and r.get("s") == sid and r.get("m") and r.get("r") not in cancelled and m.get("time", 0) >= turn_start - 2:
                                ids.append(m["id"])
                                ctl = "REPLY" + json.dumps({"decision": "block", "reason": str(r["m"])[:4000]})
                                out["continued"] = str(r.get("r") or True)
                                break
                    open(state, "w").write(" ".join([str(time.time())] + ids[-50:]))
            except Exception:
                pass
        \#(imageLines)print(json.dumps(out))
        if ctl:
            print(ctl)
        ' 2>/dev/null) || exit 0
        payload=$(printf '%s\n' "$result" | head -n 1)
        nohup curl -s -m 5 -d "$payload" "\#(publish)" >/dev/null 2>&1 &
        ctl=$(printf '%s\n' "$result" | sed -n 2p)
        if [ "$ctl" = "STOP" ]; then
          echo '{"continue":false,"stopReason":"Stopped from Turbo"}'
        elif [ "${ctl#REPLY}" != "$ctl" ]; then
          printf '%s\n' "${ctl#REPLY}"
        fi
        exit 0
        """#
    }

    /// What Turbo posts to hand a cloud session your reply when its turn ends.
    public static func replyMessage(sessionID: String, text: String, replyID: String = UUID().uuidString) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["t": "reply", "s": sessionID, "m": text, "r": replyID], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Where reply attachments are uploaded for cloud sessions (ntfy keeps them for a few hours).
    public static func filesURL(channel: String, server: URL = defaultServer) -> URL {
        server.appendingPathComponent(channel + "-files")
    }

    /// The text added to a reply so Claude can fetch its attachments.
    public static func attachmentNote(local: [String], links: [(name: String, url: String)]) -> String {
        var lines: [String] = []
        if !local.isEmpty {
            lines.append("Attached files (on this Mac):")
            lines += local
        }
        if !links.isEmpty {
            lines.append("Attached files. Download each with curl -L -o <name> <url>:")
            lines += links.map { "\($0.name): \($0.url)" }
        }
        return lines.joined(separator: "\n")
    }

    /// Takes back a reply that hasn't been picked up yet.
    public static func cancelMessage(sessionID: String, replyID: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["t": "cancel", "s": sessionID, "r": replyID], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
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

    // MARK: Cowork plugin

    /// Turbo as a Cowork plugin: the same relay, run by Cowork's plugin hooks, for Cowork tasks
    /// that run in the cloud. Returns the plugin's files (path → contents); the relay script is the
    /// one file that must be executable.
    /// What a saved plugin was built with. When this changes (new channel, sharing turned on or
    /// off), the installed plugin is out of date and needs uploading again.
    public static func coworkPluginSignature(channel: String, shareTitles: Bool) -> String {
        "\(channel)|\(shareTitles ? "share" : "private")|v2"
    }

    public static func coworkPlugin(channel: String, server: URL = defaultServer, shareTitles: Bool = false) -> [String: String] {
        // Quoted, so an install path with spaces still runs.
        let command = "\"${CLAUDE_PLUGIN_ROOT}/hooks/turbo-relay.sh\""
        var hooks: [String: Any] = [:]
        for event in events {
            var group: [String: Any] = ["hooks": [["type": "command", "command": command]]]
            if event == "PreToolUse" || event == "PostToolUse" { group["matcher"] = "*" }
            hooks[event] = [group]
        }
        let manifest: [String: Any] = [
            "name": "turbo",
            "version": "1.0.0",
            "description": "Shows your Cowork tasks in Turbo, on your Mac's notch: progress, steps, done and Stop.",
            "author": ["name": "BetterCampus"],
        ]
        func json(_ object: Any) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        return [
            ".claude-plugin/plugin.json": json(manifest),
            "hooks/hooks.json": json(["hooks": hooks]),
            "hooks/turbo-relay.sh": relayScript(channel: channel, server: server, shareTitles: shareTitles, source: "cowork"),
            "README.md": """
            # Turbo for Cowork

            Reports what your Cowork tasks are doing to the Turbo app on your Mac, through your private
            channel. It sends the event, the folder name and Claude's one-line description of each step\(shareTitles ? ", plus your prompts, images you paste in them and Claude's final replies" : ""). Never code files.
            """,
        ]
    }
}

