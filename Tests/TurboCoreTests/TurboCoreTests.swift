import XCTest
@testable import TurboCore

final class EventParserTests: XCTestCase {
    func testClaudeHookEvents() throws {
        let prompt = #"{"hook_event_name":"UserPromptSubmit","session_id":"abc","cwd":"/Users/me/app","transcript_path":"/t.jsonl","prompt":"hi"}"#
        let event = try XCTUnwrap(EventParser.parseClaudeHook(Data(prompt.utf8)))
        XCTAssertEqual(event.agent, .claude)
        XCTAssertEqual(event.sessionID, "abc")
        XCTAssertEqual(event.cwd, "/Users/me/app")
        XCTAssertEqual(event.kind, .promptSubmitted)
        XCTAssertEqual(event.transcriptPath, "/t.jsonl")

        let tool = #"{"hook_event_name":"PreToolUse","session_id":"abc","tool_name":"Bash"}"#
        XCTAssertEqual(EventParser.parseClaudeHook(Data(tool.utf8))?.kind, .activity(tool: "Bash"))

        let stop = #"{"hook_event_name":"Stop","session_id":"abc","stop_hook_active":false}"#
        XCTAssertEqual(EventParser.parseClaudeHook(Data(stop.utf8))?.kind, .turnComplete(summary: nil))

        let permission = #"{"hook_event_name":"Notification","session_id":"abc","message":"Claude needs your permission to use Bash"}"#
        XCTAssertEqual(EventParser.parseClaudeHook(Data(permission.utf8))?.kind, .needsInput(message: "Claude needs your permission to use Bash"))
    }

    func testClaudeIdleNotificationIgnored() {
        let idle = #"{"hook_event_name":"Notification","session_id":"abc","message":"Claude is waiting for your input"}"#
        XCTAssertNil(EventParser.parseClaudeHook(Data(idle.utf8)))
        let typed = #"{"hook_event_name":"Notification","session_id":"abc","notification_type":"idle_prompt","message":"x"}"#
        XCTAssertNil(EventParser.parseClaudeHook(Data(typed.utf8)))
    }

    func testCodexNotify() throws {
        let json = #"{"type":"agent-turn-complete","turn-id":"1","thread-id":"T1","input-messages":["fix it"],"last-assistant-message":"Fixed the bug."}"#
        let event = try XCTUnwrap(EventParser.parseCodexNotify(Data(json.utf8)))
        XCTAssertEqual(event.agent, .codex)
        XCTAssertEqual(event.sessionID, "T1")
        XCTAssertEqual(event.kind, .turnComplete(summary: "Fixed the bug."))

        let noID = #"{"type":"agent-turn-complete","last-assistant-message":"ok"}"#
        XCTAssertNil(try XCTUnwrap(EventParser.parseCodexNotify(Data(noID.utf8))).sessionID)
        XCTAssertNil(EventParser.parseCodexNotify(Data(#"{"type":"other"}"#.utf8)))
    }

    func testCodexRolloutLines() {
        func parse(_ s: String) -> EventParser.RolloutLine? { EventParser.parseCodexRolloutLine(Data(s.utf8)) }
        XCTAssertEqual(parse(#"{"type":"session_meta","payload":{"id":"S1","cwd":"/w"}}"#), .meta(id: "S1", cwd: "/w"))
        XCTAssertEqual(parse(#"{"type":"event_msg","payload":{"type":"task_started"}}"#), .event(.promptSubmitted))
        XCTAssertEqual(parse(#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}"#), .event(.turnComplete(summary: "done")))
        XCTAssertEqual(parse(#"{"type":"response_item","payload":{"type":"function_call","name":"shell"}}"#), .event(.activity(tool: "shell")))
        XCTAssertNil(parse(#"{"type":"event_msg","payload":{"type":"token_count"}}"#))
        XCTAssertNil(parse("not json"))
    }
}

final class SessionStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func event(_ kind: AgentEventKind, agent: Agent = .claude, id: String? = "s1", at offset: TimeInterval) -> AgentEvent {
        AgentEvent(agent: agent, sessionID: id, cwd: "/Users/me/proj", kind: kind, date: t0.addingTimeInterval(offset))
    }

    func testFullTurn() throws {
        let store = SessionStore()
        XCTAssertEqual(store.apply(event(.promptSubmitted, at: 0)).count, 1)
        guard case .beat = store.apply(event(.activity(tool: "Bash"), at: 5)).first else { return XCTFail() }
        guard case .needsInput = store.apply(event(.needsInput(message: "perm"), at: 6)).first else { return XCTFail() }
        guard case .resumed = store.apply(event(.activity(tool: "Bash"), at: 9)).first else { return XCTFail() }
        let changes = store.apply(event(.turnComplete(summary: "All done"), at: 75))
        guard case let .finished(session) = changes.first else { return XCTFail() }
        XCTAssertEqual(session.cookDuration, 75)
        XCTAssertEqual(session.beats, 2)
        XCTAssertEqual(session.projectName, "proj")
        XCTAssertEqual(session.summary, "All done")
        XCTAssertTrue(store.active.isEmpty)
    }

    func testActivityWithoutPromptStartsTurn() {
        let store = SessionStore()
        guard case .started = store.apply(event(.activity(tool: nil), at: 0)).first else { return XCTFail() }
        XCTAssertEqual(store.active.count, 1)
    }

    func testDuplicateCompletionIsDeduped() {
        let store = SessionStore()
        store.apply(event(.promptSubmitted, agent: .codex, id: "T1", at: 0))
        XCTAssertEqual(store.apply(event(.turnComplete(summary: nil), agent: .codex, id: "T1", at: 10)).count, 1)
        XCTAssertEqual(store.apply(event(.turnComplete(summary: "late"), agent: .codex, id: "T1", at: 11)).count, 0)
        XCTAssertEqual(store.sessions["codex:T1"]?.summary, "late")
        // Stray activity right after completion doesn't restart the turn…
        XCTAssertEqual(store.apply(event(.activity(tool: nil), agent: .codex, id: "T1", at: 12)).count, 0)
        // …but activity well after does.
        guard case .started = store.apply(event(.activity(tool: nil), agent: .codex, id: "T1", at: 60)).first else { return XCTFail() }
    }

    func testNilSessionIDResolvesToActiveSession() {
        let store = SessionStore()
        store.apply(event(.promptSubmitted, agent: .codex, id: "old", at: 0))
        store.apply(event(.turnComplete(summary: nil), agent: .codex, id: "old", at: 5))
        store.apply(event(.promptSubmitted, agent: .codex, id: "new", at: 10))
        guard case let .finished(s) = store.apply(event(.turnComplete(summary: "x"), agent: .codex, id: nil, at: 20)).first else { return XCTFail() }
        XCTAssertEqual(s.sessionID, "new")
        XCTAssertEqual(store.sessions.count, 2)
    }

    func testPruneAndSessionEnd() {
        let store = SessionStore()
        store.apply(event(.promptSubmitted, id: "a", at: 0))
        store.apply(event(.promptSubmitted, id: "b", at: 0))
        XCTAssertEqual(store.apply(event(.sessionEnded, id: "b", at: 1)), [.removed(id: "claude:b")])
        XCTAssertEqual(store.prune(now: t0.addingTimeInterval(60)).count, 0)
        XCTAssertEqual(store.prune(now: t0.addingTimeInterval(store.staleAfter + 1)), [.removed(id: "claude:a")])
    }
}

final class CloudRelayTests: XCTestCase {
    func testRelayLineBecomesCloudEvent() throws {
        let line = #"{"id":"abc123","time":1,"event":"message","topic":"turbo-x","message":"{\"hook_event_name\":\"Stop\",\"session_id\":\"s9\",\"cwd\":\"Turbo\",\"remote_session_id\":\"cse_01Rbct\"}"}"#
        let parsed = try XCTUnwrap(EventParser.parseRelayLine(Data(line.utf8)))
        XCTAssertEqual(parsed.id, "abc123")
        let event = try XCTUnwrap(parsed.event)
        XCTAssertEqual(event.agent, .cloud)
        XCTAssertEqual(event.kind, .turnComplete(summary: nil))
        XCTAssertEqual(event.cwd, "Turbo")
        XCTAssertEqual(event.link?.absoluteString, "https://claude.ai/code/session_01Rbct")
    }

    func testRelayIgnoresKeepalivesAndJunk() {
        XCTAssertNil(EventParser.parseRelayLine(Data(#"{"id":"k","event":"keepalive"}"#.utf8)))
        XCTAssertNil(EventParser.parseRelayLine(Data(#"{"id":"o","event":"open"}"#.utf8)))
        let junk = EventParser.parseRelayLine(Data(#"{"id":"m","event":"message","message":"hello"}"#.utf8))
        XCTAssertEqual(junk?.id, "m")
        XCTAssertNil(junk?.event ?? nil)
    }

    func testChannelAndURLs() {
        let channel = CloudRelay.newChannel()
        XCTAssertTrue(channel.hasPrefix("turbo-"))
        XCTAssertEqual(channel.count, 30)
        XCTAssertNotEqual(channel, CloudRelay.newChannel())
        XCTAssertEqual(CloudRelay.subscribeURL(channel: "c", since: "x1").absoluteString, "https://ntfy.sh/c/json?since=x1")
        XCTAssertTrue(CloudRelay.setupScript(channel: "turbo-test").contains("https://ntfy.sh/turbo-test"))
    }
}

final class CodexCloudTests: XCTestCase {
    func json(_ tasks: [(String, String, String)]) -> Data {
        let items = tasks.map { id, status, updated in
            #"{"id":"\#(id)","url":"https://chatgpt.com/codex/tasks/\#(id)","title":"Fix \#(id)","status":"\#(status)","updated_at":"\#(updated)","environment_id":"env1","environment_label":"waffle-web","summary":"did \#(id)","is_review":false,"attempt_total":1}"#
        }
        return Data(#"{"tasks":[\#(items.joined(separator: ","))],"cursor":null}"#.utf8)
    }

    func testParseList() throws {
        let tasks = try XCTUnwrap(CodexCloud.parseList(json([("t1", "running", "1")])))
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].environment, "waffle-web")
        XCTAssertEqual(tasks[0].url?.absoluteString, "https://chatgpt.com/codex/tasks/t1")
        XCTAssertNil(CodexCloud.parseList(Data("nope".utf8)))
    }

    func testStatusMatching() {
        XCTAssertEqual(CodexCloud.Phase(status: "in_progress"), .working)
        XCTAssertEqual(CodexCloud.Phase(status: "PENDING"), .working)
        XCTAssertEqual(CodexCloud.Phase(status: "ready"), .done)
        XCTAssertEqual(CodexCloud.Phase(status: "completed"), .done)
        XCTAssertEqual(CodexCloud.Phase(status: "applied"), .done)
        XCTAssertEqual(CodexCloud.Phase(status: "error"), .failed)
        XCTAssertEqual(CodexCloud.Phase(status: "cancelled"), .failed)
        XCTAssertEqual(CodexCloud.Phase(status: "weird"), .unknown)
    }

    func testTrackerOnlyAnnouncesTransitions() {
        let tracker = CodexCloud.Tracker()
        func poll(_ tasks: [(String, String, String)]) -> [AgentEventKind] {
            tracker.update(with: CodexCloud.parseList(json(tasks))!).map(\.kind)
        }
        // First poll: the running task appears, the old finished one stays quiet.
        XCTAssertEqual(poll([("t1", "running", "1"), ("old", "ready", "0")]), [.promptSubmitted])
        // Still running with no changes: a heartbeat, so long tasks never look stale.
        XCTAssertEqual(poll([("t1", "running", "1"), ("old", "ready", "0")]), [.activity(tool: nil)])
        // It finishes and a new one starts.
        XCTAssertEqual(poll([("t1", "ready", "3"), ("t2", "pending", "3")]), [.turnComplete(summary: "did t1"), .promptSubmitted])
        // ready → applied is not a second completion.
        XCTAssertEqual(poll([("t1", "applied", "4"), ("t2", "running", "4")]), [.activity(tool: nil)])
        // A failure is reported as a failure.
        XCTAssertEqual(poll([("t2", "error", "5")]), [.turnFailed(summary: "did t2")])
        // A finished task first seen late doesn't get announced.
        XCTAssertEqual(poll([("late", "completed", "6")]), [])
    }

    func testMissingActiveTasksAndReset() {
        let tracker = CodexCloud.Tracker()
        _ = tracker.update(with: CodexCloud.parseList(json([("t1", "running", "1"), ("t2", "ready", "1")]))!)
        XCTAssertEqual(tracker.activeIDs(missingFrom: CodexCloud.parseList(json([("t3", "running", "2")]))!), ["t1"])
        tracker.reset()
        // After a reset the finished task is "first seen" again, so it stays quiet.
        XCTAssertEqual(tracker.update(with: CodexCloud.parseList(json([("t1", "ready", "3")]))!).map(\.kind), [])
    }

    func testFailedTurnMarksSession() {
        let store = SessionStore()
        store.apply(AgentEvent(agent: .codexCloud, sessionID: "x", kind: .promptSubmitted))
        guard case let .finished(s) = store.apply(AgentEvent(agent: .codexCloud, sessionID: "x", kind: .turnFailed(summary: "boom"))).first else { return XCTFail() }
        XCTAssertTrue(s.failed)
        XCTAssertEqual(s.summary, "boom")
        guard case let .started(again) = store.apply(AgentEvent(agent: .codexCloud, sessionID: "x", kind: .promptSubmitted, date: Date().addingTimeInterval(60))).first else { return XCTFail() }
        XCTAssertFalse(again.failed)
    }

    func testTrackerFeedsStore() {
        let tracker = CodexCloud.Tracker()
        let store = SessionStore()
        for e in tracker.update(with: CodexCloud.parseList(json([("t1", "running", "1")]))!) { store.apply(e) }
        var finished: AgentSession?
        for e in tracker.update(with: CodexCloud.parseList(json([("t1", "ready", "2")]))!) {
            if case let .finished(s) = store.apply(e).first { finished = s }
        }
        XCTAssertEqual(finished?.projectName, "Fix t1")
        XCTAssertEqual(finished?.link?.absoluteString, "https://chatgpt.com/codex/tasks/t1")
    }
}

final class UpdateInfoTests: XCTestCase {
    // Not `release`: on macOS that name collides with NSObject's -release and crashes XCTest.
    let releaseJSON = #"{"tag_name":"latest-build","published_at":"2026-10-04T06:25:49Z","body":"Built from main @ 4061f61 (build 42).\n\n**Install**...","assets":[{"id":609300000,"name":"Turbo.zip","size":2240349}]}"#

    func testParseRelease() throws {
        let info = try XCTUnwrap(UpdateInfo.parse(release: Data(releaseJSON.utf8)))
        XCTAssertEqual(info.commit, "4061f61")
        XCTAssertEqual(info.assetID, 609300000)
        XCTAssertEqual(info.assetSize, 2240349)
        XCTAssertNil(UpdateInfo.parse(release: Data(#"{"body":"no commit","assets":[]}"#.utf8)))
    }

    func testNewerComparison() throws {
        let info = try XCTUnwrap(UpdateInfo.parse(release: Data(releaseJSON.utf8)))
        XCTAssertEqual(info.build, 42)
        // Same build: nothing to do.
        XCTAssertFalse(info.isNewer(thanInstalledBuild: 42, commit: "4061f61fa4715b7270d71280f24ffcb7de759fe2"))
        // Older CI build: update.
        XCTAssertTrue(info.isNewer(thanInstalledBuild: 41, commit: "2cf2267d91d6f2fb6db717ec5a7785b396d1a0b0"))
        // Newer build than the release (e.g. a local or branch build): never downgrade.
        XCTAssertFalse(info.isNewer(thanInstalledBuild: 50, commit: "aaaaaaa"))
        // Local builds carry no build number: no prompts.
        XCTAssertFalse(info.isNewer(thanInstalledBuild: nil, commit: "dev"))
        // Releases from before build numbers aren't offered either.
        var old = info
        old.build = nil
        XCTAssertFalse(old.isNewer(thanInstalledBuild: 41, commit: "2cf2267"))
    }
}

final class ApprovalTests: XCTestCase {
    func testParsePermissionRequest() throws {
        let bash = #"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/w/app","tool_name":"Bash","tool_input":{"command":"npm test\nnpm run lint"}}"#
        let ask = try XCTUnwrap(EventParser.parsePermissionRequest(Data(bash.utf8)))
        XCTAssertEqual(ask.sessionID, "s1")
        XCTAssertEqual(ask.tool, "Bash")
        XCTAssertEqual(ask.detail, "npm test npm run lint")
        XCTAssertTrue(ask.isComplete)
        let long = #"{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo "# + String(repeating: "x", count: 200) + #" && rm -rf build"}}"#
        let longAsk = try XCTUnwrap(EventParser.parsePermissionRequest(Data(long.utf8)))
        XCTAssertFalse(longAsk.isComplete)
        XCTAssertEqual(longAsk.detail?.count, 100)
        let edit = #"{"session_id":"s1","tool_name":"Edit","tool_input":{"file_path":"/w/app/Sources/Store.swift"}}"#
        XCTAssertEqual(EventParser.parsePermissionRequest(Data(edit.utf8))?.detail, "Store.swift")
        XCTAssertNil(EventParser.parsePermissionRequest(Data("{}".utf8)))
    }

    func testDecisionJSON() throws {
        let allow = try XCTUnwrap(EventParser.jsonObject(Data(EventParser.permissionDecision(allow: true).utf8)))
        let out = try XCTUnwrap(allow["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(out["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((out["decision"] as? [String: Any])?["behavior"] as? String, "allow")
        XCTAssertTrue(EventParser.permissionDecision(allow: false).contains(#""behavior":"deny""#))
    }

    func testApprovalHookInstalled() throws {
        let data = try HookInstaller.installClaude(into: nil)
        XCTAssertTrue(HookInstaller.isClaudeApprovalInstalled(data))
        let root = try XCTUnwrap(EventParser.jsonObject(data))
        let group = try XCTUnwrap(((root["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.first)
        let hook = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["timeout"] as? Int, 90)
        XCTAssertFalse((hook["command"] as? String ?? "").contains(" >/dev/null"), "the answer must reach stdout (only stderr is silenced)")
        let removed = try HookInstaller.uninstallClaude(from: data)
        XCTAssertFalse(HookInstaller.isClaudeApprovalInstalled(removed))
    }

    func testStepsAndPrompt() {
        let store = SessionStore()
        store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .promptSubmitted, prompt: "  Fix the login bug  "))
        for tool in ["Read", "Read", "Edit", "Edit", "Bash"] {
            store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .activity(tool: tool)))
        }
        let s = store.sessions["claude:a"]
        XCTAssertEqual(s?.lastPrompt, "Fix the login bug")
        XCTAssertEqual(s?.recentSteps, ["Read", "Edit", "Bash"])
    }
}

final class HTTPTests: XCTestCase {
    func testParseAndRoute() throws {
        let body = #"{"hook_event_name":"Stop","session_id":"z"}"#
        let raw = "POST /hook/claude?app=com.apple.Terminal&term=Apple_Terminal HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case let .complete(request) = HTTPParser.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(request.path, "/hook/claude")
        XCTAssertEqual(request.query["app"], "com.apple.Terminal")
        let event = try XCTUnwrap(EventRouter.event(for: request))
        XCTAssertEqual(event.kind, .turnComplete(summary: nil))
        XCTAssertEqual(event.hostAppBundleID, "com.apple.Terminal")
    }

    func testIncompleteBody() {
        let raw = "POST /hook/codex HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\""
        XCTAssertEqual(HTTPParser.parse(Data(raw.utf8)), .incomplete)
        XCTAssertEqual(HTTPParser.parse(Data("POST /x HTTP/1.1\r\n".utf8)), .incomplete)
    }

    func testHostAppFallback() {
        XCTAssertEqual(HostApp.bundleID(app: "", termProgram: "iTerm.app"), "com.googlecode.iterm2")
        XCTAssertNil(HostApp.bundleID(app: nil, termProgram: "unknown"))
    }
}

final class HookInstallerTests: XCTestCase {
    func testClaudeInstallPreservesExistingHooksAndIsIdempotent() throws {
        let existing = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let once = try HookInstaller.installClaude(into: Data(existing.utf8))
        let twice = try HookInstaller.installClaude(into: once)
        XCTAssertEqual(once, twice)
        XCTAssertTrue(HookInstaller.isClaudeInstalled(twice))

        let root = try XCTUnwrap(EventParser.jsonObject(twice))
        XCTAssertEqual(root["model"] as? String, "opus")
        let stop = try XCTUnwrap((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)

        let removed = try HookInstaller.uninstallClaude(from: twice)
        XCTAssertFalse(HookInstaller.isClaudeInstalled(removed))
        let after = try XCTUnwrap(EventParser.jsonObject(removed))
        let stopAfter = try XCTUnwrap((after["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopAfter.count, 1)
        XCTAssertNil((after["hooks"] as? [String: Any])?["PreToolUse"])
    }

    func testClaudeInstallIntoMissingFile() throws {
        let data = try HookInstaller.installClaude(into: nil)
        XCTAssertTrue(HookInstaller.isClaudeInstalled(data))
        XCTAssertThrowsError(try HookInstaller.installClaude(into: Data("[1]".utf8)))
    }

    func testCodexInstall() {
        let toml = "model = \"o3\"\n\n[mcp_servers.x]\ncommand = \"y\"\n"
        guard case let .installed(updated) = HookInstaller.installCodex(into: toml) else { return XCTFail() }
        XCTAssertTrue(HookInstaller.isCodexInstalled(updated))
        XCTAssertTrue(updated.hasSuffix(toml))
        XCTAssertEqual(HookInstaller.installCodex(into: updated), .alreadyInstalled)
        XCTAssertEqual(HookInstaller.uninstallCodex(from: updated), toml)
    }

    func testCodexConflictWithMultilineNotify() {
        let toml = "notify = [\n  \"python3\",\n  \"/x/notify.py\",\n]\n[tui]\n"
        guard case let .conflict(existing) = HookInstaller.installCodex(into: toml) else { return XCTFail() }
        XCTAssertTrue(existing.contains("notify.py"))
        // A notify key inside a table isn't top-level.
        XCTAssertNil(HookInstaller.topLevelNotify(in: "[profiles.a]\nnotify = [\"x\"]\n"))
    }
}

final class TailerAndFormatTests: XCTestCase {
    func testTailerEmitsOnlyNewLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turbo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: now)
        let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-2025-01-01T00-00-00-5973b6c0-94b8-487b-a530-2aeb6098ae0e.jsonl")
        try Data((#"{"type":"session_meta","payload":{"id":"S1","cwd":"/w/proj"}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n").utf8).write(to: file)

        let tailer = SessionLogTailer(source: CodexRolloutSource(root: root))
        var events: [AgentEvent] = []
        tailer.onEvent = { events.append($0) }
        tailer.poll(now: now)
        XCTAssertTrue(events.isEmpty, "history must not replay")

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((#"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n" + #"{"type":"response_item","payload":{"type":"funct"#).utf8))
        tailer.poll(now: now)
        handle.write(Data((#"ion_call","name":"shell"}}"# + "\n").utf8))
        try handle.close()
        tailer.poll(now: now)

        XCTAssertEqual(events.map(\.kind), [.promptSubmitted, .activity(tool: "shell")])
        XCTAssertEqual(events.first?.sessionID, "S1")
        XCTAssertEqual(events.first?.cwd, "/w/proj")
    }

    func testCoworkTailer() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("turbo-cowork-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let space = root.appendingPathComponent("acct-1/space-1")
        let oldSession = space.appendingPathComponent("local_old")
        try fm.createDirectory(at: oldSession, withIntermediateDirectories: true)
        let oldAudit = oldSession.appendingPathComponent("audit.jsonl")
        // A previously finished turn that must not re-announce itself.
        try Data((#"{"type":"user","message":{"role":"user","content":"hi"}}"# + "\n" + #"{"type":"result","result":"old"}"# + "\n").utf8).write(to: oldAudit)

        let tailer = SessionLogTailer(source: CoworkSessionSource(root: root))
        tailer.rediscoverInterval = 0
        var events: [AgentEvent] = []
        tailer.onEvent = { events.append($0) }
        let t0 = Date()
        tailer.poll(now: t0)
        XCTAssertTrue(events.isEmpty)

        // A brand-new session appears with its manifest.
        let newSession = space.appendingPathComponent("local_new")
        try fm.createDirectory(at: newSession, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"local_new","title":"Sort my receipts","userSelectedFolders":["/Users/me/Receipts"]}"#.utf8)
            .write(to: space.appendingPathComponent("local_new.json"))
        let lines = [
            #"{"type":"system","subtype":"init","cwd":"/sessions/brave-owl"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"sort these"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"result","subtype":"success","result":"Sorted 41 receipts.","num_turns":3}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: newSession.appendingPathComponent("audit.jsonl"))
        tailer.poll(now: t0.addingTimeInterval(1))

        XCTAssertEqual(events.map(\.kind), [.promptSubmitted, .activity(tool: "Bash"), .activity(tool: nil), .turnComplete(summary: "Sorted 41 receipts.")])
        let first = try XCTUnwrap(events.first)
        XCTAssertEqual(first.agent, .cowork)
        XCTAssertEqual(first.sessionID, "local_new")
        XCTAssertEqual(first.title, "Sort my receipts")
        XCTAssertEqual(first.cwd, "/Users/me/Receipts")
        XCTAssertEqual(first.hostAppBundleID, CoworkSessionSource.desktopBundleID)

        // The old session resumes: only the new lines count.
        events.removeAll()
        let handle = try FileHandle(forWritingTo: oldAudit)
        handle.seekToEndOfFile()
        handle.write(Data((#"{"type":"user","message":{"content":"again"}}"# + "\n").utf8))
        try handle.close()
        tailer.poll(now: t0.addingTimeInterval(2))
        XCTAssertEqual(events.map(\.kind), [.promptSubmitted])
    }

    func testCoworkStoreUsesTitle() {
        let store = SessionStore()
        let changes = store.apply(AgentEvent(agent: .cowork, sessionID: "local_x", cwd: "/Users/me/Receipts", kind: .promptSubmitted, title: "Sort my receipts"))
        guard case let .started(s) = changes.first else { return XCTFail() }
        XCTAssertEqual(s.projectName, "Sort my receipts")
    }

    func testSessionIDFromFileName() {
        XCTAssertEqual(CodexRolloutSource.sessionID(fromFileName: "rollout-2025-05-07T17-24-21-5973B6C0-94b8-487b-a530-2aeb6098ae0e.jsonl"), "5973b6c0-94b8-487b-a530-2aeb6098ae0e")
    }

    func testTranscriptAndFormat() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"## Done\\nShipped the fix."}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}
        """
        let text = ClaudeTranscript.lastAssistantText(inJSONL: Data(jsonl.utf8))
        XCTAssertEqual(text, "## Done\nShipped the fix.")
        XCTAssertEqual(Format.snippet(text), "Done")
        XCTAssertEqual(Format.duration(75), "1m 15s")
        XCTAssertEqual(Format.clock(3700), "1:01:40")
    }
}

final class SessionNamingTests: XCTestCase {
    func testTitleFromPrompt() {
        XCTAssertEqual(SessionNaming.title(fromPrompt: "can you build the note style picker for the LMS please?"), "Build the note style picker for…")
        XCTAssertEqual(SessionNaming.title(fromPrompt: "fix login bug"), "Fix login bug")
        XCTAssertNil(SessionNaming.title(fromPrompt: "<environment_context>cwd</environment_context>"))
        XCTAssertNil(SessionNaming.title(fromPrompt: "   "))
    }

    func testOpaqueFoldersAreHidden() {
        XCTAssertNil(SessionNaming.repoName(fromPath: "/Users/j/.codex/.chatgpt-projects/g-p-6781bfff18808191a31dfc769598c765"))
        XCTAssertEqual(SessionNaming.repoName(fromPath: "/w/waffle-web"), "waffle-web")
    }

    func testSessionNamedByFirstPrompt() {
        let store = SessionStore()
        let now = Date()
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", cwd: "/w/web", kind: .promptSubmitted, prompt: "Add dark mode to settings", date: now))
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .promptSubmitted, prompt: "now run the tests", date: now))
        let s = store.sorted.first
        XCTAssertEqual(s?.projectName, "Add dark mode to settings")
        XCTAssertEqual(s?.place, "web")
    }

    func testCodexUserMessageNamesSession() {
        let line = #"{"type":"event_msg","payload":{"type":"user_message","message":"Refactor the billing module"}}"#
        XCTAssertEqual(EventParser.parseCodexRolloutLine(Data(line.utf8)), .prompt("Refactor the billing module"))
    }
}

final class TriageTests: XCTestCase {
    func testNeedsInputSinceTracksWaiting() {
        let store = SessionStore()
        let t0 = Date()
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .promptSubmitted, date: t0))
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .needsInput(message: "x"), date: t0.addingTimeInterval(5)))
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .needsInput(message: "y"), date: t0.addingTimeInterval(9)))
        XCTAssertEqual(store.sorted.first?.needsInputSince, t0.addingTimeInterval(5))
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .activity(tool: "Bash"), date: t0.addingTimeInterval(12)))
        XCTAssertNil(store.sorted.first?.needsInputSince)
    }

    func testAllowRuleOnlyForSimpleCommands() throws {
        func ask(_ cmd: String) -> String? {
            let json = try! JSONSerialization.data(withJSONObject: ["session_id": "s", "tool_name": "Bash", "tool_input": ["command": cmd]])
            return EventParser.parsePermissionRequest(json)?.rule
        }
        XCTAssertEqual(ask("npm test"), "Bash(npm test)")
        XCTAssertNil(ask("npm test\nrm -rf /"))
        XCTAssertNil(ask("echo $(whoami)"))
    }

    func testAddingAllowRuleKeepsSettings() throws {
        let existing = Data(#"{"model":"opus","permissions":{"allow":["Read"],"deny":["Bash(rm:*)"]}}"#.utf8)
        let out = try HookInstaller.addingAllowRule("Bash(npm test)", to: existing)
        let again = try HookInstaller.addingAllowRule("Bash(npm test)", to: out)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: again) as? [String: Any])
        let perms = try XCTUnwrap(root["permissions"] as? [String: Any])
        XCTAssertEqual(perms["allow"] as? [String], ["Read", "Bash(npm test)"])
        XCTAssertEqual(perms["deny"] as? [String], ["Bash(rm:*)"])
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertNotNil(try HookInstaller.addingAllowRule("Bash(ls)", to: nil))
    }
}
