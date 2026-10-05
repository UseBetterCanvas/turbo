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

final class ActivityDetailTests: XCTestCase {
    func testBashDescriptionBecomesActivity() throws {
        let json = #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"gh api ...","description":"Wait for Greptile review on PR #8"}}"#
        let event = try XCTUnwrap(EventParser.parseClaudeHook(Data(json.utf8)))
        XCTAssertEqual(event.activityDetail, "Wait for Greptile review on PR #8")
        let store = SessionStore()
        _ = store.apply(event)
        XCTAssertEqual(store.sorted.first?.activityDetail, "Wait for Greptile review on PR #8")
    }

    func testTodoActiveForm() throws {
        let json = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"Add tests","activeForm":"Adding tests","status":"completed"},{"content":"Fix CI","activeForm":"Fixing CI","status":"in_progress"}]}}"#
        XCTAssertEqual(EventParser.parseClaudeHook(Data(json.utf8))?.activityDetail, "Fixing CI")
    }

    func testRelayActivityAndTitle() throws {
        let inner = #"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"Clippy","prompt":"Build the note style picker","activity":"Reading files"}"#
        let envelope = try JSONSerialization.data(withJSONObject: ["event": "message", "id": "1", "message": inner])
        let event = try XCTUnwrap(EventParser.parseRelayLine(envelope)?.event)
        XCTAssertEqual(event.prompt, "Build the note style picker")
        XCTAssertEqual(event.activityDetail, "Reading files")
    }

    func testSetupScriptTitlesAreOptIn() {
        XCTAssertFalse(CloudRelay.setupScript(channel: "turbo-x").contains("UserPromptSubmit\":"))
        XCTAssertFalse(CloudRelay.relayScript(channel: "turbo-x").contains("out[\"prompt\"]"))
        XCTAssertTrue(CloudRelay.relayScript(channel: "turbo-x", shareTitles: true).contains("out[\"prompt\"]"))
        XCTAssertTrue(CloudRelay.relayScript(channel: "turbo-x", shareTitles: true).contains("out[\"reply\"]"))
        let quotes = { (s: String) in s.filter { $0 == "'" }.count }
        XCTAssertEqual(quotes(CloudRelay.relayScript(channel: "turbo-x", shareTitles: true)), quotes(CloudRelay.relayScript(channel: "turbo-x")), "the python runs inside single quotes")
    }

    /// Runs the relay's python on a sample hook payload, so a quoting slip can't ship.
    func testRelayPythonRuns() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("no python3") }
        for share in [false, true] {
            let script = CloudRelay.relayScript(channel: "turbo-x", shareTitles: share)
            let start = try XCTUnwrap(script.range(of: "python3 -c '")).upperBound
            let end = try XCTUnwrap(script.range(of: "' 2>/dev/null) || exit 0")).lowerBound
            let code = String(script[start..<end])
            let process = Process()
            process.executableURL = python
            process.arguments = ["-c", code]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/w/Clippy","prompt":"please fix the flaky syrup tests now ok","tool_input":{"description":"Run tests"}}"#.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let firstLine = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").first ?? ""
            let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
            XCTAssertEqual(out["cwd"] as? String, "Clippy")
            XCTAssertEqual(out["activity"] as? String, "Run tests")
            XCTAssertEqual(out["prompt"] as? String, share ? "please fix the flaky syrup tests now ok" : nil)
        }
    }
}


final class StopTests: XCTestCase {
    func testStopRequestIsConsumedOnce() {
        let stops = StopRequests()
        stops.request("s1")
        XCTAssertTrue(stops.consume("s1"))
        XCTAssertFalse(stops.consume("s1"))
        XCTAssertEqual(StopRequests.gateResponse(stop: false), "")
        XCTAssertTrue(StopRequests.gateResponse(stop: true).contains(#""continue":false"#))
    }

    func testInstallUsesGateForPreToolUse() throws {
        let data = try HookInstaller.installClaude(into: nil)
        XCTAssertTrue(HookInstaller.isClaudeInstalled(data))
        XCTAssertTrue(HookInstaller.isClaudeStopInstalled(data))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let post = try XCTUnwrap((hooks["PostToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        XCTAssertTrue((post.first?["command"] as? String)?.contains(">/dev/null 2>&1") == true, "only the gate keeps its output")
        let pre = try XCTUnwrap((hooks["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        XCTAssertFalse((pre.first?["command"] as? String)?.contains(">/dev/null 2>&1") == true)
    }

    func testGateRequestsRouteAsClaudeEvents() {
        let body = Data(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash"}"#.utf8)
        let request = HTTPRequest(method: "POST", path: HookInstaller.gatePath, query: [:], headers: [:], body: body)
        XCTAssertEqual(EventRouter.event(for: request)?.agent, .claude)
    }

    /// Runs the whole relay script through bash, with curl stubbed out, so the shell quoting is proven too.
    func testRelayScriptRunsInBash() throws {
        let bash = URL(fileURLWithPath: "/bin/bash")
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turbo-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeCurl = dir.appendingPathComponent("curl")
        try "#!/bin/sh\nexit 0\n".write(to: fakeCurl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCurl.path)
        // A stand-in stop server: python's file server answers /turbo-x-stop/json with one stop message.
        let served = dir.appendingPathComponent("www/turbo-x-stop")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try #"{"id":"m1","event":"message","message":"stop s"}"#.write(to: served.appendingPathComponent("json"), atomically: true, encoding: .utf8)
        let port = Int.random(in: 20000...40000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", dir.appendingPathComponent("www").path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        Thread.sleep(forTimeInterval: 0.8)
        let script = dir.appendingPathComponent("relay.sh")
        try CloudRelay.relayScript(channel: "turbo-x", server: URL(string: "http://127.0.0.1:\(port)")!, shareTitles: true).write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = bash
        process.arguments = [script.path]
        process.environment = ["PATH": dir.path + ":/usr/bin:/bin", "HOME": dir.path, "NO_PROXY": "*", "no_proxy": "*"]
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"description":"Run tests"}}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                       #"{"continue":false,"stopReason":"Stopped from Turbo"}"# + "\n")
        // The same stop message is only acted on once.
        let state = try String(contentsOf: dir.appendingPathComponent(".claude/turbo-stop-state"), encoding: .utf8)
        XCTAssertTrue(state.contains("m1"))
    }
}


final class TranscriptTurnTests: XCTestCase {
    func testCurrentTurnOnlyStopsAtTheLastPrompt() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"first ask"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"old reply"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"second ask"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
        ].joined(separator: "\n")
        let data = Data(lines.utf8)
        XCTAssertEqual(ClaudeTranscript.lastAssistantText(inJSONL: data), "old reply")
        XCTAssertNil(ClaudeTranscript.lastAssistantText(inJSONL: data, currentTurnOnly: true))
        let answered = Data((lines + "\n" + #"{"type":"assistant","message":{"content":[{"type":"text","text":"new reply"}]}}"#).utf8)
        XCTAssertEqual(ClaudeTranscript.lastAssistantText(inJSONL: answered, currentTurnOnly: true), "new reply")
    }
}

final class CoworkTranscriptTests: XCTestCase {
    /// The layout the Claude app uses now: each task runs Claude Code and keeps its transcript
    /// at local_<id>/.claude/projects/<slug>/<uuid>.jsonl, with no "result" line at the end.
    func testCoworkTranscriptLayout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("turbo-cowork-t-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let space = root.appendingPathComponent("2ce5ffac/acb2bdc7")
        let task = space.appendingPathComponent("local_0aa0dafc")
        let project = task.appendingPathComponent(".claude/projects/-Users-me-local-0aa0dafc-out")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"title":"Plan the offsite","userSelectedFolders":["/Users/me/Offsite"]}"#.utf8)
            .write(to: space.appendingPathComponent("local_0aa0dafc.json"))
        let transcript = project.appendingPathComponent("2bcd6a7e.jsonl")
        try Data().write(to: transcript)

        let tailer = SessionLogTailer(source: CoworkSessionSource(root: root))
        tailer.rediscoverInterval = 0
        tailer.finishDelay = 5
        var events: [AgentEvent] = []
        tailer.onEvent = { events.append($0) }
        let t0 = Date()
        tailer.poll(now: t0)
        XCTAssertTrue(events.isEmpty)

        func append(_ lines: [String]) throws {
            let handle = try FileHandle(forWritingTo: transcript)
            handle.seekToEndOfFile()
            handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            try handle.close()
        }
        try append([
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"x","timestamp":"t"}"#,
            #"{"type":"user","message":{"role":"user","content":"Plan our team offsite"},"isSidechain":false}"#,
            #"{"type":"attachment","attachment":{},"isSidechain":false}"#,
            #"{"type":"last-prompt","leafUuid":"a","sessionId":"x"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."}]},"isSidechain":false}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]},"isSidechain":false}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]},"isSidechain":false}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Here's the plan."}],"stop_reason":null},"isSidechain":false}"#,
        ])
        tailer.poll(now: t0.addingTimeInterval(1))
        XCTAssertEqual(events.map(\.kind), [.promptSubmitted, .activity(tool: nil), .activity(tool: "Read"), .activity(tool: nil), .activity(tool: nil)])
        let first = try XCTUnwrap(events.first)
        XCTAssertEqual(first.agent, .cowork)
        XCTAssertEqual(first.sessionID, "local_0aa0dafc")
        XCTAssertEqual(first.title, "Plan the offsite")
        XCTAssertEqual(first.cwd, "/Users/me/Offsite")
        XCTAssertEqual(first.prompt, "Plan our team offsite")
        XCTAssertEqual(first.transcriptPath, transcript.path)

        // Still within the quiet window: not done yet.
        events.removeAll()
        tailer.poll(now: t0.addingTimeInterval(3))
        XCTAssertTrue(events.isEmpty)
        // Quiet long enough after a final-looking reply: the turn is done.
        tailer.poll(now: t0.addingTimeInterval(7))
        XCTAssertEqual(events.map(\.kind), [.turnComplete(summary: "Here's the plan.")])
        // And only once.
        tailer.poll(now: t0.addingTimeInterval(20))
        XCTAssertEqual(events.count, 1)

        // A progress line followed by a slow tool call is not a finish.
        events.removeAll()
        try append([
            #"{"type":"user","message":{"role":"user","content":"Now book the venue"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me check availability."}]}}"#,
        ])
        tailer.poll(now: t0.addingTimeInterval(8))
        tailer.poll(now: t0.addingTimeInterval(11))
        try append([#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{}}]}}"#])
        tailer.poll(now: t0.addingTimeInterval(12))
        tailer.poll(now: t0.addingTimeInterval(19))
        XCTAssertFalse(events.contains { if case .turnComplete = $0.kind { return true } else { return false } })
        try append([#"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#])
        tailer.poll(now: t0.addingTimeInterval(20))

        // An explicit end_turn finishes right away.
        events.removeAll()
        try append([
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Add a budget"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Budget added."}],"stop_reason":"end_turn"}}"#,
        ])
        events.removeAll()
        tailer.poll(now: t0.addingTimeInterval(21))
        XCTAssertEqual(events.map(\.kind), [.promptSubmitted, .turnComplete(summary: "Budget added.")])
        tailer.poll(now: t0.addingTimeInterval(40))
        XCTAssertEqual(events.count, 2)
    }

    func testTranscriptSidechainAndCommandsAreProgress() {
        func kind(_ s: String) -> EventParser.RolloutLine? { EventParser.parseClaudeTranscriptLine(Data(s.utf8))?.kind }
        XCTAssertEqual(kind(#"{"type":"user","isSidechain":true,"message":{"content":"sub task"}}"#), .event(.activity(tool: nil)))
        XCTAssertEqual(kind(#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#), .event(.activity(tool: nil)))
        XCTAssertNil(kind(#"{"type":"user","isMeta":true,"message":{"content":"caveat"}}"#))
        XCTAssertNil(kind(#"{"type":"queue-operation","operation":"enqueue"}"#))
    }
}

final class CloudReplyTests: XCTestCase {
    /// With sharing on, the Stop hook reads Claude's last reply from the transcript.
    func testRelaySendsFinalReplyOnStop() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("no python3") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turbo-reply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        try [
            #"{"type":"user","message":{"content":"fix it"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed the bug."}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent noise"}]}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let script = CloudRelay.relayScript(channel: "turbo-x", shareTitles: true)
        let start = try XCTUnwrap(script.range(of: "python3 -c '")).upperBound
        let end = try XCTUnwrap(script.range(of: "' 2>/dev/null) || exit 0")).lowerBound
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", String(script[start..<end])]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let hook = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s", "cwd": "/w/app", "transcript_path": transcript.path])
        input.fileHandleForWriting.write(hook)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let firstLine = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").first ?? ""
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
        XCTAssertEqual(out["reply"] as? String, "Fixed the bug.")
        // And the Mac reads it as the turn's summary.
        let envelope = try JSONSerialization.data(withJSONObject: ["event": "message", "id": "1", "message": String(firstLine)])
        XCTAssertEqual(EventParser.parseRelayLine(envelope)?.event?.kind, .turnComplete(summary: "Fixed the bug."))
    }

    func testThreadRecordsTheConversation() {
        let store = SessionStore()
        let t = Date()
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .promptSubmitted, prompt: "Fix login", date: t))
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .activity(tool: "Bash"), date: t).with(activityDetail: "Run tests"))
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .activity(tool: "Bash"), date: t).with(activityDetail: "Run tests"))
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .needsInput(message: "Wants to run rm"), date: t))
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .activity(tool: "Bash"), date: t))
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "a", kind: .turnComplete(summary: "Login fixed."), date: t))
        let kinds = store.sorted.first?.thread.map(\.kind)
        XCTAssertEqual(kinds, [.prompt, .step(tool: "Bash"), .needs, .step(tool: "Bash"), .reply, .finished(failed: false)])
        // A summary that shows up later lands before the "done" line, once.
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "b", kind: .promptSubmitted, prompt: "Go", date: t))
        _ = store.apply(AgentEvent(agent: .claude, sessionID: "b", kind: .turnComplete(summary: nil), date: t))
        store.setSummary("All done.", for: "claude:b")
        store.setSummary("All done.", for: "claude:b")
        XCTAssertEqual(store.sessions["claude:b"]?.thread.map(\.kind), [.prompt, .reply, .finished(failed: false)])
    }
}

final class TranscriptThreadTests: XCTestCase {
    func testTranscriptBecomesAConversation() {
        let lines = [
            #"{"type":"user","timestamp":"2026-10-05T10:00:00.000Z","message":{"role":"user","content":"Fix the login bug"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking now."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/w/app/Login.swift"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"..."}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test","description":"Run tests"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed it."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Tests pass."}]}}"#,
            #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
        ].joined(separator: "\n")
        let items = ClaudeTranscript.thread(inJSONL: Data(lines.utf8))
        XCTAssertEqual(items.map(\.kind), [.prompt, .reply, .step(tool: "Read"), .step(tool: "Bash"), .reply])
        XCTAssertEqual(items.map(\.text), ["Fix the login bug", "Looking now.", "Login.swift", "Run tests", "Fixed it.\n\nTests pass."])
        XCTAssertEqual(items.first?.date, ISO8601DateFormatter().date(from: "2026-10-05T10:00:00Z"))
    }
}
