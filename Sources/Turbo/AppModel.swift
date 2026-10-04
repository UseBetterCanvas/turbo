import AppKit
import TurboCore
import Combine
import ServiceManagement
import SwiftUI

/// What the island shows when it's expanded on its own (not because of hover).
struct Spotlight: Equatable {
    enum Kind: Equatable {
        case finished
        case needsInput
    }

    var kind: Kind
    var session: AgentSession
}

/// Turbo is always exactly one of three shapes, all growing out of the notch: a tiny island
/// (idle or cooking), a medium island (a done/needs-you card, or the hover list), or the
/// pop-up. `hidden` only means "the pop-up is showing instead".
enum IslandPresentation: Equatable {
    case hidden
    /// Tiny island, nothing cooking: the paw beside the notch.
    case idle
    /// Tiny island while sessions cook: flame, timer, count.
    case compact
    case spotlight(Spotlight)
    case list
}

/// A moment the visualizer reacts to.
struct Pulse {
    enum Kind {
        case start
        case beat
        case needsInput
        case finish
    }

    let agent: Agent
    let kind: Kind
    /// The tool behind a beat, so the visualizer can react to what's actually happening.
    var tool: String? = nil
}

/// A Claude Code permission prompt waiting on Allow or Deny.
struct PendingApproval {
    let token = UUID()
    let tool: String
    let detail: String?
    let respond: @Sendable (String) -> Void
}

/// Sessions grouped by what they need from you, most urgent first.
struct SessionBoard {
    var needsYou: [AgentSession] = []
    var cooking: [AgentSession] = []
    var done: [AgentSession] = []

    var all: [AgentSession] { needsYou + cooking + done }
    var activeCount: Int { needsYou.count + cooking.count }

    init(_ sessions: [AgentSession]) {
        for session in sessions {
            switch session.phase {
            case .needsInput: needsYou.append(session)
            case .cooking: cooking.append(session)
            case .done, .idle: done.append(session)
            }
        }
        needsYou.sort { $0.lastActivityAt > $1.lastActivityAt }
        // Longest-running first: that's the one you've been waiting on.
        cooking.sort { ($0.turnStartedAt ?? .distantFuture) < ($1.turnStartedAt ?? .distantFuture) }
        done.sort { ($0.finishedAt ?? $0.lastActivityAt) > ($1.finishedAt ?? $1.lastActivityAt) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let preferences = Preferences()
    let neighbors = NotchNeighbors()
    let pulses = PassthroughSubject<Pulse, Never>()
    let updater = Updater()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var spotlight: Spotlight?
    /// Done/needs-you cards waiting their turn when several sessions land at once.
    @Published private(set) var spotlightQueue: [Spotlight] = []
    /// The pointer is over the island right now (drives hit-testing and hover polish).
    @Published private(set) var pointerInside = false
    /// The pointer has rested on the island long enough to expand it. Lags `pointerInside` a
    /// little so passing the cursor through the menu bar doesn't flash the list open.
    @Published private(set) var isHoveringIsland = false
    @Published private(set) var serverError: String?
    /// When Turbo last heard anything from each agent — powers "Connected · heard 2m ago".
    @Published private(set) var lastHeard: [Agent: Date] = [:]
    @Published private(set) var relayState: RelayListener.State = .off
    @Published private(set) var codexCloudState: CodexCloudPoller.State = .off
    @Published private(set) var lastRelayMessage: Date?
    /// Permission prompts you can answer from Turbo, by session id.
    @Published private(set) var approvals: [String: PendingApproval] = [:]
    /// The session whose details are showing in the hover list.
    @Published var detailSessionID: String?
    @Published var popupOpen = false
    @Published var popupPage: PopupPage = .home

    private let store = SessionStore()
    private let server = EventServer()
    private let relay = RelayListener()
    private let codexCloud = CodexCloudPoller()
    private let codexTailer = SessionLogTailer(source: CodexRolloutSource())
    private let coworkTailer = SessionLogTailer(source: CoworkSessionSource())
    private var hoverTask: Task<Void, Never>?
    private var expandRequested = false
    private var loops: [Task<Void, Never>] = []
    private var spotlightTask: Task<Void, Never>?
    private var island: IslandPanelController?
    private var popup: PopupController?
    private(set) lazy var visualizer = VisualizerWindowController(model: self)
    private var forwarding = Set<AnyCancellable>()

    private init() {
        // Placement depends on other notch apps; let views observing the model hear about it.
        neighbors.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarding)
    }

    var board: SessionBoard { SessionBoard(sessions) }
    var active: [AgentSession] { sessions.filter { $0.phase.isActive } }
    var hasActive: Bool { sessions.contains { $0.phase.isActive } }
    var needsYouCount: Int { sessions.filter { if case .needsInput = $0.phase { return true } else { return false } }.count }

    /// Whether the island sits in the notch, or floats below it to share with another notch app.
    var isDocked: Bool {
        switch preferences.islandPlacement {
        case .notch: return true
        case .belowNotch: return false
        case .automatic: return neighbors.running.isEmpty
        }
    }

    var presentation: IslandPresentation {
        if popupOpen { return .hidden }
        if let spotlight { return .spotlight(spotlight) }
        if isHoveringIsland { return .list }
        if hasActive { return .compact }
        return .idle
    }

    // MARK: Lifecycle

    func start() {
        server.onRequest = { [weak self] request in
            guard let self else { return }
            // Count any hook call as a sign of life, even ones we don't act on (like tests).
            if request.path == "/hook/claude" { self.lastHeard[.claude] = Date() }
            if request.path == "/hook/codex" { self.lastHeard[.codex] = Date() }
            guard let event = EventRouter.event(for: request) else { return }
            self.handle(event)
        }
        server.onFailure = { [weak self] message in self?.serverError = message }
        server.onPermission = { [weak self] request, respond in
            guard let self else { respond(""); return }
            self.lastHeard[.claude] = Date()
            self.askForApproval(request, respond: respond)
        }
        do {
            try server.start(port: UInt16(HookInstaller.defaultPort))
        } catch {
            serverError = "Couldn't listen on port \(HookInstaller.defaultPort): \(error.localizedDescription)"
        }

        for tailer in [codexTailer, coworkTailer] {
            tailer.onEvent = { [weak self] event in self?.handle(event) }
        }
        pollLogs()
        loops.append(every(seconds: 1) { [weak self] in self?.pollLogs() })
        loops.append(every(seconds: 30) { [weak self] in
            guard let self else { return }
            for change in self.store.prune() { self.react(to: change) }
            self.sessions = self.store.sorted
        })

        relay.onEvent = { [weak self] event in self?.handle(event) }
        relay.onState = { [weak self] state in self?.relayState = state }
        relay.onMessage = { [weak self] in
            self?.lastRelayMessage = Date()
            self?.lastHeard[.cloud] = Date()
        }
        preferences.$cloudEnabled.combineLatest(preferences.$cloudChannel)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] enabled, channel in
                if enabled { self?.relay.start(channel: channel) } else { self?.relay.stop() }
            }
            .store(in: &forwarding)

        codexCloud.onEvents = { [weak self] events in events.forEach { self?.handle($0) } }
        codexCloud.onState = { [weak self] state in
            self?.codexCloudState = state
            if case .watching = state { self?.lastHeard[.codexCloud] = Date() }
        }
        preferences.$watchCodexCloud
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.codexCloud.start() } else { self?.codexCloud.stop() }
            }
            .store(in: &forwarding)

        updater.start()

        island = IslandPanelController(model: self)
        island?.show()
        popup = PopupController(model: self)

        if !preferences.hasOnboarded { openPopup(.welcome) }
    }

    private func pollLogs() {
        if preferences.watchCodexSessions { codexTailer.poll() }
        if preferences.watchCoworkSessions { coworkTailer.poll() }
    }

    /// `expand: false` keeps the island as it is while the pointer is over a control on it
    /// (the idle gear), so the control doesn't move away before it's clicked.
    func setPointerInside(_ inside: Bool, expand: Bool = true) {
        let wantsExpand = inside && expand
        guard inside != pointerInside || wantsExpand != expandRequested else { return }
        pointerInside = inside
        expandRequested = wantsExpand
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: wantsExpand ? 140_000_000 : 260_000_000)
            guard let self, !Task.isCancelled, self.expandRequested == wantsExpand else { return }
            self.isHoveringIsland = wantsExpand
            if !wantsExpand { self.detailSessionID = nil }
        }
    }

    private func every(seconds: Double, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                body()
            }
        }
    }

    // MARK: Events

    func handle(_ event: AgentEvent) {
        if !(event.sessionID ?? "").hasPrefix("demo-") { lastHeard[event.agent] = event.date }
        let changes = store.apply(event)
        sessions = store.sorted
        for change in changes { react(to: change) }
    }

    private func react(to change: StoreChange) {
        switch change {
        case let .started(session):
            pulses.send(Pulse(agent: session.agent, kind: .start))
            dropSpotlights(for: session.id)
            if preferences.visualizerAutoOpen {
                visualizer.show()
            }

        case let .beat(session):
            pulses.send(Pulse(agent: session.agent, kind: .beat, tool: session.lastTool))

        case let .resumed(session):
            pulses.send(Pulse(agent: session.agent, kind: .beat, tool: session.lastTool))
            dropSpotlights(for: session.id, kind: .needsInput)

        case let .needsInput(session):
            pulses.send(Pulse(agent: session.agent, kind: .needsInput))
            enqueue(Spotlight(kind: .needsInput, session: session))
            playSound(named: "Tink")

        case let .finished(session):
            pulses.send(Pulse(agent: session.agent, kind: .finish))
            approvals.removeValue(forKey: session.id)?.respond("")
            dropSpotlights(for: session.id, kind: .needsInput)
            // nil duration means we never saw it start — still worth announcing.
            let worthCelebrating = (session.cookDuration ?? .infinity) >= preferences.minimumCookSeconds
            if worthCelebrating {
                enqueue(Spotlight(kind: .finished, session: session))
                if session.failed {
                    playSound(named: "Basso")
                } else {
                    playSound(named: preferences.soundName)
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
            if session.summary == nil, let path = session.transcriptPath {
                loadSummary(for: session.id, transcriptPath: path)
            }
            visualizer.turnFinished(session)

        case let .removed(id):
            dropSpotlights(for: id)
            approvals.removeValue(forKey: id)?.respond("")
        }
    }

    /// The Stop hook doesn't always include the final message, so read it from the transcript.
    private func loadSummary(for id: String, transcriptPath: String) {
        Task.detached(priority: .utility) {
            // Give Claude a beat to flush the transcript.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let text = ClaudeTranscript.lastAssistantText(atPath: transcriptPath) else { return }
            await MainActor.run {
                let model = AppModel.shared
                model.store.setSummary(text, for: id)
                model.sessions = model.store.sorted
                if let current = model.spotlight, current.session.id == id, let updated = model.store.sessions[id] {
                    model.spotlight = Spotlight(kind: current.kind, session: updated)
                }
            }
        }
    }

    // MARK: Spotlight queue

    /// Shows a card now, or lines it up behind the current one. "Needs you" cuts the line.
    private func enqueue(_ item: Spotlight) {
        spotlightQueue.removeAll { $0.session.id == item.session.id }
        if spotlight == nil || spotlight?.session.id == item.session.id {
            present(item)
        } else if item.kind == .needsInput && spotlight?.kind == .finished {
            if let current = spotlight { spotlightQueue.insert(current, at: 0) }
            present(item)
        } else if item.kind == .needsInput {
            let firstFinished = spotlightQueue.firstIndex { $0.kind == .finished } ?? spotlightQueue.endIndex
            spotlightQueue.insert(item, at: firstFinished)
        } else {
            spotlightQueue.append(item)
        }
    }

    private func present(_ item: Spotlight) {
        spotlightTask?.cancel()
        spotlight = item
        guard item.kind == .finished else { return }   // "needs you" stays until resolved or dismissed
        // Several queued? Move a little faster so the line doesn't drag.
        let seconds = spotlightQueue.isEmpty ? preferences.celebrateSeconds : max(2.5, preferences.celebrateSeconds * 0.6)
        spotlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // Don't yank the card out from under the cursor.
            while let self, self.pointerInside, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.advanceSpotlight()
        }
    }

    /// Dismisses the current card and shows the next one in line, if any.
    func advanceSpotlight() {
        spotlightTask?.cancel()
        if spotlightQueue.isEmpty {
            spotlight = nil
        } else {
            present(spotlightQueue.removeFirst())
        }
    }

    func clearSpotlight() {
        spotlightTask?.cancel()
        spotlightQueue.removeAll()
        spotlight = nil
    }

    private func dropSpotlights(for id: String, kind: Spotlight.Kind? = nil) {
        spotlightQueue.removeAll { $0.session.id == id && (kind == nil || $0.kind == kind) }
        if let current = spotlight, current.session.id == id, kind == nil || current.kind == kind {
            advanceSpotlight()
        }
    }

    func islandTapped() {
        if let spotlight {
            if preferences.returnToTerminalOnClick { open(spotlight.session) }
            advanceSpotlight()
        } else {
            openPopup(.home)
        }
    }

    // MARK: Approvals

    /// A permission prompt from Claude Code. If you're already looking at the app it runs in,
    /// step aside so the prompt shows there. Otherwise offer Allow / Deny in the island for a
    /// minute, then fall back to the normal prompt.
    private func askForApproval(_ request: HTTPRequest, respond: @escaping @Sendable (String) -> Void) {
        guard let ask = EventParser.parsePermissionRequest(request.body) else { respond(""); return }
        let host = HostApp.bundleID(app: request.query["app"], termProgram: request.query["term"])
        if let host, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host {
            respond("")
            return
        }
        let key = "\(Agent.claude.rawValue):\(ask.sessionID)"
        approvals[key]?.respond("")
        let pending = PendingApproval(tool: ask.tool, detail: ask.detail, respond: respond)
        approvals[key] = pending
        handle(AgentEvent(
            agent: .claude, sessionID: ask.sessionID, cwd: ask.cwd,
            kind: .needsInput(message: Self.approvalMessage(tool: ask.tool, detail: ask.detail)),
            hostAppBundleID: host
        ))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, self.approvals[key]?.token == pending.token else { return }
            self.approvals[key] = nil
            pending.respond("")
        }
    }

    /// "Wants to run npm test", "Wants to edit Store.swift"
    static func approvalMessage(tool: String, detail: String?) -> String {
        let t = tool.lowercased()
        guard let detail, !detail.isEmpty else { return "Wants to use \(tool)" }
        if t.contains("bash") || t.contains("shell") { return "Wants to run \(detail)" }
        if t.contains("edit") || t.contains("write") { return "Wants to edit \(detail)" }
        if t.contains("fetch") || t.contains("web") { return "Wants to open \(detail)" }
        return "Wants to use \(tool): \(detail)"
    }

    func pendingApproval(for session: AgentSession) -> PendingApproval? {
        approvals[session.id]
    }

    /// Answers a permission prompt from Turbo.
    func decide(_ session: AgentSession, allow: Bool) {
        guard let pending = approvals.removeValue(forKey: session.id) else { return }
        pending.respond(EventParser.permissionDecision(allow: allow))
        handle(AgentEvent(agent: session.agent, sessionID: session.sessionID, kind: .activity(tool: allow ? pending.tool : nil)))
    }

    // MARK: Sessions

    /// Takes you to the session: its cloud page, or the app it runs in.
    func open(_ session: AgentSession) {
        if let link = session.link {
            openLink(link, for: session.agent)
            return
        }
        guard let bundleID = session.hostAppBundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        if #available(macOS 14, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    static let claudeAppBundleID = "com.anthropic.claudefordesktop"
    static let chatGPTAppBundleID = "com.openai.chat"

    /// Whether Open can use the app for this kind of session (the same check Open uses).
    static func appInstalled(for agent: Agent) -> Bool {
        if agent == .codexCloud {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: chatGPTAppBundleID) != nil
        }
        return claudeAppLink(for: URL(string: "https://claude.ai/code")!) != nil
    }

    /// The Claude app link for a claude.ai page, but only if the Claude app is the one that
    /// handles claude:// (not some other app that registered the scheme). Code sessions use the
    /// documented `claude://code/{session-id}` route; other pages keep their claude.ai path.
    static func claudeAppLink(for link: URL) -> URL? {
        let parts = link.pathComponents.filter { $0 != "/" }
        let deepString: String
        if parts.first == "code" {
            deepString = parts.count > 1 ? "claude://code/" + parts[1] : "claude://code"
        } else {
            deepString = "claude://claude.ai" + link.path
        }
        guard let deep = URL(string: deepString),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: deep),
              Bundle(url: handler)?.bundleIdentifier == claudeAppBundleID else { return nil }
        return deep
    }

    /// Opens a session's page in the Claude/ChatGPT app or the browser, per the preference.
    private func openLink(_ link: URL, for agent: Agent) {
        if preferences.openSessionsIn == .app {
            switch agent {
            case .codexCloud:
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chatGPTAppBundleID) {
                    NSWorkspace.shared.open([link], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                        // If the app can't take it, the browser still gets you there.
                        if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(link) } }
                    }
                    return
                }
            default:
                if let deep = Self.claudeAppLink(for: link) {
                    NSWorkspace.shared.open(deep)
                    return
                }
            }
        }
        NSWorkspace.shared.open(link)
    }

    func focusHost(of session: AgentSession) {
        open(session)
    }

    func dismiss(_ session: AgentSession) {
        store.remove(id: session.id)
        sessions = store.sorted
        dropSpotlights(for: session.id)
    }

    func clearFinished() {
        for session in sessions where !session.phase.isActive { store.remove(id: session.id) }
        sessions = store.sorted
    }

    private func playSound(named name: String) {
        guard preferences.playSound else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: Pop-up and windows

    func openPopup(_ page: PopupPage = .home) {
        popupPage = page
        popup?.open()
    }

    func togglePopup() {
        // One click from the menu bar always lands on the board.
        if popupOpen { popup?.close() } else { openPopup(preferences.hasOnboarded ? .home : .welcome) }
    }

    func closePopup() {
        popup?.close()
    }

    func openSettings() {
        openPopup(.settings)
    }

    func openVisualizer() {
        closePopup()
        visualizer.show()
    }

    func showOnboarding() {
        openPopup(.welcome)
    }

    func finishOnboarding() {
        preferences.hasOnboarded = true
        popupPage = .home
    }

    // MARK: Cloud relay

    var cloudSetupScript: String {
        CloudRelay.setupScript(channel: preferences.cloudChannel)
    }

    func checkCodexCloudNow() {
        codexCloud.pollNow()
    }

    func sendRelayTestPing() {
        relay.sendTestPing()
    }

    /// New channel: old setup scripts stop reaching this Mac.
    func resetCloudChannel() {
        preferences.cloudChannel = CloudRelay.newChannel()
        // Pings from the old channel no longer count as this setup working.
        lastHeard[.cloud] = nil
        lastRelayMessage = nil
    }

    // MARK: Connection test

    /// Runs the exact hook command Claude Code would, and waits to hear it arrive.
    func testClaudeConnection() async -> Bool {
        let started = Date()
        let command = HookInstaller.claudeCommand()
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(#"{"hook_event_name":"TurboConnectionTest","session_id":"turbo-test"}"#.utf8))
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
            } catch {}
        }.value
        for _ in 0..<20 {
            if let heard = lastHeard[.claude], heard >= started { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Publishes to our relay channel and waits to see it come back down the stream.
    func testCloudRelay() async -> Bool {
        let started = Date()
        relay.sendTestPing()
        for _ in 0..<50 {
            if let heard = lastRelayMessage, heard >= started { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        objectWillChange.send()
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Turbo: couldn't change launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: Demo

    /// Fakes a whole turn so people can see what happens without waiting on a real agent.
    func simulate(_ agent: Agent, seconds: Double = 9, needsInput: Bool = false) {
        let id = "demo-\(UUID().uuidString.prefix(6))"
        let cwd: String
        let tools: [String]
        let summary: String
        var title: String?
        var link: URL?
        switch agent {
        case .claude:
            cwd = "/Users/demo/pancake-stack"
            tools = ["Read", "Edit", "Bash", "Grep", "Write"]
            summary = "Stacked the pancakes: refactored the batter service and all 42 tests pass."
        case .codex:
            cwd = "/Users/demo/omelette-api"
            tools = ["shell", "apply_patch", "shell"]
            summary = "Omelette API is plated. Added the /flip endpoint with tests."
        case .cowork:
            cwd = "/Users/demo/Receipts"
            tools = ["Read", "Bash", "Write"]
            summary = "Sorted 41 receipts into folders by month and made a summary spreadsheet."
            title = "Sort my receipts"
        case .cloud:
            cwd = "waffle-web"
            tools = ["Read", "Edit", "Bash"]
            summary = "Waffle grid is crispy: fixed the layout bug and opened a PR."
            link = URL(string: "https://claude.ai/code")
        case .codexCloud:
            cwd = "crepe-service"
            tools = []
            summary = "Crepes are folded: added retries to the batter queue."
            title = "Add retries to the batter queue"
            link = URL(string: "https://chatgpt.com/codex")
        }
        let host = Bundle.main.bundleIdentifier
        func send(_ kind: AgentEventKind) {
            handle(AgentEvent(agent: agent, sessionID: id, cwd: cwd, kind: kind, hostAppBundleID: host, title: title, link: link))
        }
        Task { @MainActor in
            send(.promptSubmitted)
            let ticks = Int(seconds / 0.35)
            for tick in 0..<ticks {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if needsInput && tick == ticks / 2 {
                    send(.needsInput(message: "Claude needs your permission to use Bash"))
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                if Double.random(in: 0...1) < 0.55 { send(.activity(tool: tools.randomElement())) }
            }
            send(.turnComplete(summary: summary))
        }
    }

    /// A busy afternoon: several sessions at once, finishing at different times, one needing you.
    func simulateBusyDay() {
        simulate(.cloud, seconds: 7)
        simulate(.claude, seconds: 11, needsInput: true)
        simulate(.codex, seconds: 15)
        simulate(.cowork, seconds: 9)
        simulate(.codexCloud, seconds: 13)
    }
}
