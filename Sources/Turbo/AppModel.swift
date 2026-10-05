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
    /// The permission rule "Always Allow" saves, when one is safe to offer.
    var rule: String? = nil
    /// The project the request came from. Always Allow writes its rule here.
    var cwd: String? = nil
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
        // Waiting longest first: that's the one most likely to be stuck on you.
        needsYou.sort { ($0.needsInputSince ?? $0.lastActivityAt) < ($1.needsInputSince ?? $1.lastActivityAt) }
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
    /// Hears what the Mac is playing, for the visualizer.
    let music = MusicListener()
    @Published private(set) var musicState: MusicListener.State = .off

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var spotlight: Spotlight?
    /// Done/needs-you cards waiting their turn when several sessions land at once.
    @Published private(set) var spotlightQueue: [Spotlight] = []
    /// How long the current done card stays up (its countdown bar uses this).
    @Published private(set) var spotlightSeconds: Double = 4
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
    /// Permission prompts waiting on you, oldest first, per session.
    @Published private(set) var approvals: [String: [PendingApproval]] = [:]
    /// The session row the pointer is resting on in the hover list.
    var hoveredRowID: String?
    /// The session whose details are showing in the hover list.
    @Published var detailSessionID: String?
    /// The row picked with the keyboard on the board.
    @Published var selectedSessionID: String?
    /// Finished sessions you've already looked at. The rest count as unseen.
    @Published private(set) var seen: Set<String> = []
    /// While set and in the future: no sounds and no done cards. Needs-you still shows, silently.
    @Published private(set) var quietUntil: Date?
    /// Waiting sessions Turbo has already nudged you about again.
    private var nudged: Set<String> = []
    /// Set while Turbo updates a session's message itself, so it doesn't alert you again.
    private var updatingQuietly = false
    /// Why the last Always Allow couldn't be saved, by session.
    @Published private(set) var approvalErrors: [String: String] = [:]
    private let hotKey = GlobalHotKey()
    private let stops = StopRequests()
    /// Sessions you've pressed Stop on that haven't stopped yet.
    @Published private(set) var stopping: Set<String> = []
    /// Whether Claude Code's hooks include the stop gate (cached; reading settings per frame is wasteful).
    @Published private(set) var claudeStopReady = false

    func refreshIntegrations() {
        let ready = Integrations.isClaudeStopInstalled
        if ready != claudeStopReady { claudeStopReady = ready }
        let replies = Integrations.isClaudeReplyInstalled
        if replies != claudeReplyReady { claudeReplyReady = replies }
    }

    /// Claude Code's Stop hook asks Turbo for your queued replies.
    @Published private(set) var claudeReplyReady = false
    private let replyQueue = ReplyQueue()
    /// Replies you've typed that are waiting for the session to finish its turn, by session.
    @Published private(set) var queuedReplies: [String: [String]] = [:]
    /// A one-line note for the composer ("Copied. Paste it in the terminal.").
    @Published private(set) var composerNotes: [String: String] = [:]
    /// Your Claude plan usage, as the Claude app last recorded it.
    @Published private(set) var usage: PlanUsage?
    private var usageAlertLevel = 0
    /// Each session's commit when its turn started, to diff against when it ends.
    private var turnBaselines: [String: String] = [:]
    /// False when another app already owns ⌃⌥Space.
    @Published private(set) var hotKeyAvailable = false
    /// A step the lead session just moved on to, shown briefly under the tiny island.
    @Published private(set) var peekText: String?
    private var lastPeek = (key: "", at: Date.distantPast)
    private var peekTask: Task<Void, Never>?
    @Published var popupOpen = false
    /// The detached window is showing.
    @Published var windowOpen = false
    private(set) lazy var mainWindow = MainWindowController(model: self)
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
    /// The session the tiny island tracks: the one waiting on you longest, else the one cooking longest.
    var lead: AgentSession? { let b = board; return b.needsYou.first ?? b.cooking.first }
    /// Finished sessions you haven't opened or dismissed yet.
    var unseenDone: [AgentSession] { board.done.filter { !seen.contains($0.id) } }
    var isQuiet: Bool { (quietUntil ?? .distantPast) > Date() }
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
            if request.path == "/hook/claude" || request.path == HookInstaller.gatePath { self.lastHeard[.claude] = Date() }
            if request.path == "/hook/codex" { self.lastHeard[.codex] = Date() }
            guard let event = EventRouter.event(for: request) else { return }
            self.handle(event)
        }
        server.onFailure = { [weak self] message in self?.serverError = message }
        server.stops = stops
        server.onStopped = { [weak self] id in self?.finishStopped(agent: .claude, sessionID: id) }
        server.replies = replyQueue
        server.onReplied = { [weak self] id, text in self?.replyDelivered(agent: .claude, sessionID: id, text: text) }
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
        // Already connected? Bring Turbo's own hooks up to date (adds Stop and approvals).
        if Integrations.isClaudeInstalled && !(Integrations.isClaudeStopInstalled && Integrations.isClaudeApprovalInstalled && Integrations.isClaudeReplyInstalled) {
            try? Integrations.installClaude()
        }
        refreshIntegrations()
        refreshUsage()
        loops.append(every(seconds: 60) { [weak self] in self?.refreshUsage() })
        loops.append(every(seconds: 15) { [weak self] in
            self?.nudgeLongWaits()
            self?.refreshIntegrations()
        })
        loops.append(every(seconds: 30) { [weak self] in
            guard let self else { return }
            for change in self.store.prune() { self.react(to: change) }
            self.sessions = self.store.sorted
        })

        relay.onEvent = { [weak self] event in
            guard let self else { return }
            // Cowork switched off: ignore what the Cowork plugin reports too.
            if event.agent == .cowork && !self.preferences.watchCoworkSessions { return }
            var event = event
            // A reply you sent kept the cloud session going: show it as the new prompt.
            if event.continuedByReply {
                let key = "\(event.agent.rawValue):\(event.sessionID ?? "")"
                if let text = self.queuedReplies[key]?.first {
                    self.replyDelivered(agent: event.agent, sessionID: event.sessionID ?? "", text: text)
                    return
                }
            }
            // Sharing turned off: show nothing a not-yet-updated script or plugin still sends.
            if !self.preferences.cloudShareTitles {
                event.prompt = nil
                if case .turnComplete = event.kind { event.kind = .turnComplete(summary: nil) }
            }
            self.handle(event)
        }
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

        music.onState = { [weak self] state in self?.musicState = state }
        updater.autoInstall = { [weak self] in
            guard let self, self.preferences.autoUpdate else { return false }
            // Relaunching clears the board, so only when nothing's cooking or waiting on you.
            return !self.hasActive && !self.popupOpen && self.approvals.isEmpty
        }
        updater.start()
        hotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        hotKeyAvailable = hotKey.register()

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
            if wantsExpand && !self.isHoveringIsland {
                // A soft tick as it opens, felt on a Force Touch trackpad.
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
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
            recordBaseline(for: session)
            dropSpotlights(for: session.id)
            if preferences.visualizerAutoOpen {
                visualizer.show()
            }

        case let .beat(session):
            pulses.send(Pulse(agent: session.agent, kind: .beat, tool: session.lastTool))
            peekIfNewStep(session)

        case let .resumed(session):
            pulses.send(Pulse(agent: session.agent, kind: .beat, tool: session.lastTool))
            nudged.remove(session.id)
            dropSpotlights(for: session.id, kind: .needsInput)

        case let .needsInput(session):
            pulses.send(Pulse(agent: session.agent, kind: .needsInput))
            seen.remove(session.id)
            if updatingQuietly {
                // Same wait, new words: refresh any card that's showing, no new alert.
                if spotlight?.session.id == session.id { spotlight = Spotlight(kind: .needsInput, session: session) }
                spotlightQueue = spotlightQueue.map { $0.session.id == session.id ? Spotlight(kind: $0.kind, session: session) : $0 }
            } else {
                enqueue(Spotlight(kind: .needsInput, session: session))
                playSound(named: "Tink")
            }

        case let .finished(session):
            pulses.send(Pulse(agent: session.agent, kind: .finish))
            releaseApprovals(for: session.id)
            dropSpotlights(for: session.id, kind: .needsInput)
            // nil duration means we never saw it start — still worth announcing.
            seen.remove(session.id)
            nudged.remove(session.id)
            stopping.remove(session.id)
            computeChanges(for: session)
            returnUndeliveredReplies(for: session)
            stops.cancel(session.sessionID)
            let worthCelebrating = (session.cookDuration ?? .infinity) >= preferences.minimumCookSeconds && !isQuiet
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
            releaseApprovals(for: id)
            seen.remove(id)
            nudged.remove(id)
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
        spotlightSeconds = seconds
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
            if preferences.returnToTerminalOnClick { open(spotlight.session) } else { markSeen(spotlight.session) }
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
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Already in the terminal (or one we can't tell apart), or a command too long to show
        // in full: let the normal prompt handle it.
        let inHost = host.map { $0 == front } ?? HostApp.isTerminal(bundleID: front)
        guard !inHost, ask.isComplete else { respond(""); return }
        let key = "\(Agent.claude.rawValue):\(ask.sessionID)"
        let pending = PendingApproval(tool: ask.tool, detail: ask.detail, rule: ask.cwd == nil ? nil : ask.rule, cwd: ask.cwd, respond: respond)
        approvals[key, default: []].append(pending)
        if approvals[key]?.count == 1 { showApproval(pending, sessionID: ask.sessionID, cwd: ask.cwd, host: host) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, let queue = self.approvals[key], let index = queue.firstIndex(where: { $0.token == pending.token }) else { return }
            self.approvals[key]?.remove(at: index)
            pending.respond("")
            let rest = self.approvals[key] ?? []
            if rest.isEmpty { self.approvals[key] = nil }
            guard index == 0 else { return }
            if let next = rest.first {
                self.showApproval(next, sessionID: ask.sessionID)
            } else {
                // The prompt is now waiting in the terminal. Say so instead of offering buttons
                // that no longer work.
                if let session = self.store.sessions[key] {
                    self.updateWaitingMessage(session, to: "Answer in the terminal: " + Self.approvalMessage(tool: pending.tool, detail: pending.detail))
                }
            }
        }
    }

    /// Changes what a waiting session says, without alerting you again.
    private func updateWaitingMessage(_ session: AgentSession, to message: String) {
        updatingQuietly = true
        defer { updatingQuietly = false }
        handle(AgentEvent(agent: session.agent, sessionID: session.sessionID, kind: .needsInput(message: message)))
    }

    private func showApproval(_ pending: PendingApproval, sessionID: String, cwd: String? = nil, host: String? = nil) {
        handle(AgentEvent(
            agent: .claude, sessionID: sessionID, cwd: cwd,
            kind: .needsInput(message: Self.approvalMessage(tool: pending.tool, detail: pending.detail)),
            hostAppBundleID: host
        ))
    }

    /// Hands every open prompt for a session back to the terminal.
    private func releaseApprovals(for id: String) {
        approvals.removeValue(forKey: id)?.forEach { $0.respond("") }
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
        approvals[session.id]?.first
    }

    /// Answers a permission prompt from Turbo.
    /// Allows this request and every identical one in this repo from now on, by adding the
    /// request's rule to the project's `.claude/settings.local.json`.
    func alwaysAllow(_ session: AgentSession) {
        guard let pending = pendingApproval(for: session), let rule = pending.rule, let cwd = pending.cwd else { return }
        let url = URL(fileURLWithPath: cwd).appendingPathComponent(".claude/settings.local.json")
        do {
            // A file that exists but can't be read stops here, before anything is overwritten.
            let existing: Data? = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            let updated = try HookInstaller.addingAllowRule(rule, to: existing)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing { try existing.write(to: url.appendingPathExtension("turbo-backup"), options: .atomic) }
            try updated.write(to: url, options: .atomic)
        } catch {
            // Leave the prompt up so you can still Allow or Deny it.
            approvalErrors[session.id] = "Couldn't save Always Allow to .claude/settings.local.json. Allow or Deny this one instead."
            NSLog("Turbo: couldn't save the allow rule: \(error.localizedDescription)")
            return
        }
        approvalErrors[session.id] = nil
        decide(session, allow: true)
    }

    func decide(_ session: AgentSession, allow: Bool) {
        markSeen(session)
        approvalErrors[session.id] = nil
        guard var queue = approvals[session.id], !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        approvals[session.id] = queue.isEmpty ? nil : queue
        pending.respond(EventParser.permissionDecision(allow: allow))
        NSHapticFeedbackManager.defaultPerformer.perform(allow ? .levelChange : .generic, performanceTime: .now)
        if let next = queue.first {
            showApproval(next, sessionID: session.sessionID)
        } else {
            handle(AgentEvent(agent: session.agent, sessionID: session.sessionID, kind: .activity(tool: allow ? pending.tool : nil)))
        }
    }

    // MARK: Sessions

    /// Takes you to the session: its cloud page, or the app it runs in.
    func open(_ session: AgentSession) {
        markSeen(session)
        if popupOpen { closePopup() }
        // Heading to the terminal: give it the prompt now instead of holding it for Turbo.
        if let pending = approvals[session.id]?.first {
            releaseApprovals(for: session.id)
            updateWaitingMessage(session, to: "Answer in the terminal: " + Self.approvalMessage(tool: pending.tool, detail: pending.detail))
            dropSpotlights(for: session.id)
        }
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
        let wasSelected = selectedSessionID == session.id
        defer {
            // Showing it in full? Move on to the next one rather than an empty pane.
            if wasSelected { selectedSessionID = board.all.first?.id }
        }
        seen.remove(session.id)
        nudged.remove(session.id)
        store.remove(id: session.id)
        sessions = store.sorted
        dropSpotlights(for: session.id)
    }

    /// Whether Open has somewhere to go: a page, or the app it runs in.
    func canOpen(_ session: AgentSession) -> Bool {
        session.link != nil || session.hostAppBundleID != nil
    }

    func markSeen(_ session: AgentSession) {
        seen.insert(session.id)
    }

    // MARK: Stop

    enum StopMethod {
        /// Local Claude Code: the gate hook stops it before its next step.
        case nextStep
        /// Local Codex: interrupt the process.
        case interrupt
        /// Claude Code in the cloud: the relay checks for stops every few seconds.
        case cloud
    }

    /// How Turbo can stop this session, or nil if it can't (Open it to stop it there).
    func stopMethod(for session: AgentSession) -> StopMethod? {
        guard session.phase.isActive else { return nil }
        switch session.agent {
        case .claude: return claudeStopReady ? .nextStep : nil
        case .codex: return session.logPath == nil ? nil : .interrupt
        case .cloud: return preferences.cloudEnabled ? .cloud : nil
        // A Cowork task on this Mac has a log; one reported by the plugin runs in the cloud.
        case .cowork: return session.logPath == nil && preferences.cloudEnabled ? .cloud : nil
        case .codexCloud: return nil
        }
    }

    func stop(_ session: AgentSession) {
        guard let method = stopMethod(for: session) else { open(session); return }
        markSeen(session)
        stopping.insert(session.id)
        // Waiting on a permission prompt? Answer it with "stop" right away.
        if session.agent == .claude, var queue = approvals[session.id], !queue.isEmpty {
            let pending = queue.removeFirst()
            approvals[session.id] = nil
            pending.respond(EventParser.permissionStop)
            queue.forEach { $0.respond("") }
            finishStopped(agent: .claude, sessionID: session.sessionID)
            return
        }
        switch method {
        case .nextStep:
            stops.request(session.sessionID)
        case .interrupt:
            guard let path = session.logPath else { return }
            Task.detached(priority: .userInitiated) {
                let stopped = Self.interruptProcesses(writing: path)
                await MainActor.run {
                    let model = AppModel.shared
                    if stopped { model.finishStopped(agent: .codex, sessionID: session.sessionID) } else { model.stopping.remove(session.id); model.open(session) }
                }
            }
        case .cloud:
            var request = URLRequest(url: CloudRelay.publishURL(channel: CloudRelay.stopChannel(preferences.cloudChannel)))
            request.httpMethod = "POST"
            request.httpBody = Data(CloudRelay.stopMessage(sessionID: session.sessionID).utf8)
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    /// Takes back a Stop that hasn't landed yet.
    func cancelStop(_ session: AgentSession) {
        stops.cancel(session.sessionID)
        stopping.remove(session.id)
    }

    /// Marks a session stopped: it shows as done, with "Stopped from Turbo".
    func finishStopped(agent: Agent, sessionID: String) {
        stopping.remove("\(agent.rawValue):\(sessionID)")
        handle(AgentEvent(agent: agent, sessionID: sessionID, kind: .turnComplete(summary: "Stopped from Turbo")))
    }

    /// Sends Ctrl+C (SIGINT) to whatever has this log file open: the Codex run writing it.
    nonisolated static func interruptProcesses(writing path: String) -> Bool {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-t", path]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return false }
        lsof.waitUntilExit()
        let pids = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
            .filter { $0 != getpid() }
        for pid in pids { kill(pid, SIGINT) }
        return !pids.isEmpty
    }

    // MARK: Replies

    enum ReplyRoute: Equatable {
        /// Denies the waiting permission prompt with your message, which Claude reads as what to do instead.
        case denyWithNote
        /// Handed to Claude when its current turn ends; it carries on with it.
        case queueLocal
        case queueCloud
        /// Can't be delivered from here: copied, and the session opens so you can paste it.
        case copyAndOpen
    }

    func replyRoute(for session: AgentSession) -> ReplyRoute {
        if pendingApproval(for: session) != nil { return .denyWithNote }
        guard session.phase.isActive else { return .copyAndOpen }
        switch session.agent {
        case .claude: return claudeReplyReady ? .queueLocal : .copyAndOpen
        case .cloud: return preferences.cloudEnabled ? .queueCloud : .copyAndOpen
        case .cowork: return session.logPath == nil && preferences.cloudEnabled ? .queueCloud : .copyAndOpen
        case .codex, .codexCloud: return .copyAndOpen
        }
    }

    func send(_ raw: String, to session: AgentSession) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerNotes[session.id] = nil
        markSeen(session)
        switch replyRoute(for: session) {
        case .denyWithNote:
            guard var queue = approvals[session.id], !queue.isEmpty else { return }
            let pending = queue.removeFirst()
            approvals[session.id] = queue.isEmpty ? nil : queue
            pending.respond(EventParser.permissionDeny(message: text))
            handle(AgentEvent(agent: session.agent, sessionID: session.sessionID, kind: .activity(tool: nil)))
            store.appendThread(.prompt, text, to: session.id)
            sessions = store.sorted
        case .queueLocal:
            replyQueue.enqueue(text, for: session.sessionID)
            queuedReplies[session.id, default: []].append(text)
        case .queueCloud:
            queuedReplies[session.id, default: []].append(text)
            var request = URLRequest(url: CloudRelay.publishURL(channel: CloudRelay.stopChannel(preferences.cloudChannel)))
            request.httpMethod = "POST"
            request.httpBody = Data(CloudRelay.replyMessage(sessionID: session.sessionID, text: text).utf8)
            URLSession.shared.dataTask(with: request).resume()
        case .copyAndOpen:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            composerNotes[session.id] = "Copied. Paste it in the session (⌘V)."
            if canOpen(session) { open(session) }
        }
    }

    /// Takes back replies that haven't gone out yet (local only: cloud ones are already posted).
    func cancelQueuedReplies(for session: AgentSession) {
        replyQueue.clear(session.sessionID)
        queuedReplies[session.id] = nil
    }

    private func replyDelivered(agent: Agent, sessionID: String, text: String) {
        let key = "\(agent.rawValue):\(sessionID)"
        if var list = queuedReplies[key], let index = list.firstIndex(of: text) {
            list.remove(at: index)
            queuedReplies[key] = list.isEmpty ? nil : list
        }
        handle(AgentEvent(agent: agent, sessionID: sessionID, kind: .promptSubmitted, prompt: text))
    }

    /// The turn ended before your reply could ride along: hand it back on the clipboard.
    private func returnUndeliveredReplies(for session: AgentSession) {
        guard let list = queuedReplies[session.id], !list.isEmpty else { return }
        replyQueue.clear(session.sessionID)
        queuedReplies[session.id] = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(list.joined(separator: "\n\n"), forType: .string)
        composerNotes[session.id] = "It finished before your reply went out. It's copied: paste it in the session."
    }

    // MARK: Changes

    private func recordBaseline(for session: AgentSession) {
        guard let cwd = session.cwd, !session.agent.isCloud, session.logPath == nil || session.agent == .codex else { return }
        let id = session.id
        Task.detached(priority: .utility) {
            let head = Self.git(["rev-parse", "HEAD"], in: cwd)?.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { if let head, !head.isEmpty { AppModel.shared.turnBaselines[id] = head } }
        }
    }

    /// Local sessions: what changed since the turn began, from git.
    private func computeChanges(for session: AgentSession) {
        guard session.changes == nil, let cwd = session.cwd, !session.agent.isCloud,
              FileManager.default.fileExists(atPath: cwd) else { return }
        let id = session.id
        let base = turnBaselines.removeValue(forKey: id) ?? "HEAD"
        Task.detached(priority: .utility) {
            guard let numstat = Self.git(["diff", "--numstat", base], in: cwd) else { return }
            let changes = ChangeSummary.parse(numstat: numstat)
            guard changes.files > 0 else { return }
            await MainActor.run {
                let model = AppModel.shared
                model.store.setChanges(changes, for: id)
                model.sessions = model.store.sorted
            }
        }
    }

    nonisolated static func git(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    // MARK: Usage

    /// Reads the Claude app's latest plan-usage sample, and gives one heads-up as the 5-hour
    /// session limit passes 80% and again at 95%.
    private func refreshUsage() {
        Task.detached(priority: .utility) {
            let latest = PlanUsage.load()
            await MainActor.run {
                let model = AppModel.shared
                if latest != model.usage { model.usage = latest }
                guard let latest else { return }
                let level = latest.fiveHour >= 95 ? 2 : latest.fiveHour >= 80 ? 1 : 0
                if level > model.usageAlertLevel {
                    model.playSound(named: "Funk")
                    model.announce("\(latest.fiveHour)% of your 5-hour session limit used")
                }
                model.usageAlertLevel = level
            }
        }
    }

    // MARK: Peek

    /// The tiny island grows for a moment to show the step the session it tracks moved on to.
    /// At most every 6 seconds, so a busy session doesn't make it flicker.
    /// Shows a short line under the tiny island for a few seconds.
    func announce(_ text: String) {
        peekText = text
        peekTask?.cancel()
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.peekText = nil
        }
    }

    private func peekIfNewStep(_ session: AgentSession) {
        guard preferences.showStepPeeks, presentation == .compact, session.id == lead?.id,
              let detail = session.activityDetail else { return }
        let key = session.id + "|" + detail
        guard key != lastPeek.key, Date().timeIntervalSince(lastPeek.at) >= 6 else { return }
        lastPeek = (key, Date())
        peekText = detail
        peekTask?.cancel()
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            self?.peekText = nil
        }
    }

    // MARK: Triage

    /// Waiting more than a few minutes? Nudge once more, in case the first card got missed.
    private func nudgeLongWaits(now: Date = Date()) {
        for session in board.needsYou {
            guard let since = session.needsInputSince, now.timeIntervalSince(since) >= 180, !nudged.contains(session.id) else { continue }
            nudged.insert(session.id)
            playSound(named: "Tink")
            enqueue(Spotlight(kind: .needsInput, session: session))
        }
    }

    /// Quiet for a while (nil turns alerts back on).
    func setQuiet(for seconds: TimeInterval?) {
        quietUntil = seconds.map { Date().addingTimeInterval($0) }
        if seconds != nil {
            spotlightQueue.removeAll { $0.kind == .finished }
            if spotlight?.kind == .finished { advanceSpotlight() }
        }
    }

    /// ⌃⌥Space: open the board on whatever needs you, or close it.
    private func hotKeyPressed() {
        if popupOpen && popupPage == .home { closePopup(); return }
        if windowOpen && mainWindow.isKey { mainWindow.close(); return }
        openPopup(preferences.hasOnboarded ? .home : .welcome)
    }

    /// Keyboard triage on the board. Returns false for keys it doesn't use.
    func handleBoardKey(_ characters: String, keyCode: UInt16) -> Bool {
        guard popupOpen || windowOpen, popupPage == .home else { return false }
        let list = board.all
        guard !list.isEmpty else { return false }
        let index = list.firstIndex { $0.id == selectedSessionID }
        let selected = index.map { list[$0] }
        func select(_ i: Int) { selectedSessionID = list[max(0, min(list.count - 1, i))].id }
        switch (keyCode, characters.lowercased()) {
        case (125, _), (_, "j"): select((index ?? -1) + 1)
        case (126, _), (_, "k"): select((index ?? 1) - 1)
        case (36, _), (76, _): if let selected, canOpen(selected) { open(selected) }
        case (_, "a"): if let selected, pendingApproval(for: selected) != nil { decide(selected, allow: true) }
        case (_, "d"): if let selected, pendingApproval(for: selected) != nil { decide(selected, allow: false) }
        case (_, "s"): if let selected, stopMethod(for: selected) != nil { stop(selected) }
        case (51, _), (_, "x"):
            guard let selected, !selected.phase.isActive, let i = index else { return true }
            dismiss(selected)
            let rest = board.all
            selectedSessionID = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
        default:
            if let digit = Int(characters), (1...9).contains(digit), digit <= list.count {
                if canOpen(list[digit - 1]) { open(list[digit - 1]) } else { selectedSessionID = list[digit - 1].id }
                return true
            }
            return false
        }
        return true
    }

    func clearFinished() {
        for session in sessions where !session.phase.isActive { store.remove(id: session.id) }
        sessions = store.sorted
    }

    func playSound(named name: String) {
        guard preferences.playSound, !isQuiet else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: Pop-up and windows

    /// The pop-up becomes a regular window you can keep beside your work.
    func detachToWindow() {
        closePopup()
        mainWindow.show()
    }

    /// Back from the window to the notch.
    func attachToNotch() {
        mainWindow.close()
        openPopup(popupPage == .welcome ? .welcome : .home)
    }

    func openPopup(_ page: PopupPage = .home) {
        popupPage = page
        if page == .home {
            // Something waiting? Open on it. Otherwise keep the pick, or show the hello.
            let current = board
            if let waiting = current.needsYou.first {
                selectedSessionID = waiting.id
            } else if !current.all.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = nil
            }
        }
        if windowOpen {
            mainWindow.show()
            return
        }
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

    /// You copied a setup script before, and the current one is different (new features, or
    /// you changed a setting it depends on). Paste the new one to get them.
    var cloudScriptOutdated: Bool {
        !preferences.copiedCloudScript.isEmpty && preferences.copiedCloudScript != cloudSetupScript
    }

    func copyCloudSetupScript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cloudSetupScript, forType: .string)
        preferences.copiedCloudScript = cloudSetupScript
    }

    /// The Cowork plugin you saved was built for a different channel or sharing choice.
    var coworkPluginOutdated: Bool {
        !preferences.savedCoworkPlugin.isEmpty
            && preferences.savedCoworkPlugin != CloudRelay.coworkPluginSignature(channel: preferences.cloudChannel, shareTitles: preferences.cloudShareTitles)
    }

    /// Writes Turbo-for-Cowork.zip to Downloads and returns it. Only once it's saved does Turbo
    /// start listening for Cowork through the private channel.
    func saveCoworkPlugin() throws -> URL {
        let fm = FileManager.default
        let channel = preferences.cloudChannel, share = preferences.cloudShareTitles
        let scratch = fm.temporaryDirectory.appendingPathComponent("turbo-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let work = scratch.appendingPathComponent("turbo", isDirectory: true)
        for (path, contents) in CloudRelay.coworkPlugin(channel: channel, shareTitles: share) {
            let url = work.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            if path.hasSuffix(".sh") { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        // Build the new zip beside the work files, then swap it in, so a failure keeps the old one.
        let fresh = scratch.appendingPathComponent("Turbo-for-Cowork.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", work.path, fresh.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        let zip = downloads.appendingPathComponent("Turbo-for-Cowork.zip")
        if fm.fileExists(atPath: zip.path) {
            _ = try fm.replaceItemAt(zip, withItemAt: fresh)
        } else {
            try fm.moveItem(at: fresh, to: zip)
        }
        preferences.savedCoworkPlugin = CloudRelay.coworkPluginSignature(channel: channel, shareTitles: share)
        if !preferences.watchCoworkSessions { preferences.watchCoworkSessions = true }
        if !preferences.cloudEnabled { preferences.cloudEnabled = true }
        return zip
    }

    var cloudSetupScript: String {
        CloudRelay.setupScript(channel: preferences.cloudChannel, shareTitles: preferences.cloudShareTitles)
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
        var prompt: String?
        switch agent {
        case .claude:
            cwd = "/Users/demo/pancake-stack"
            tools = ["Read", "Edit", "Bash", "Grep", "Write"]
            summary = "Stacked the pancakes: refactored the batter service and all 42 tests pass."
            prompt = ["Refactor the batter service", "Fix the flaky syrup tests", "Add a stack height limit"].randomElement()
        case .codex:
            cwd = "/Users/demo/omelette-api"
            tools = ["shell", "apply_patch", "shell"]
            summary = "Omelette API is plated. Added the /flip endpoint with tests."
            prompt = "Add a /flip endpoint with tests"
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
            handle(AgentEvent(agent: agent, sessionID: id, cwd: cwd, kind: .promptSubmitted, hostAppBundleID: host, title: title, link: link, prompt: prompt))
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
