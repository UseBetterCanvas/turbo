import Foundation

/// What a tailer knows about one log file's session.
public struct SessionLogContext: Equatable {
    public var sessionID: String
    public var cwd: String?
    public var title: String?
    public var hostAppBundleID: String?
    /// The prompt behind the line being parsed, passed along with its event.
    public var prompt: String?
    /// A sidecar file worth re-reading later (Cowork writes the session title after the fact).
    public var sidecar: URL?

    public init(sessionID: String, cwd: String? = nil, title: String? = nil, hostAppBundleID: String? = nil, sidecar: URL? = nil) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.hostAppBundleID = hostAppBundleID
        self.sidecar = sidecar
    }
}

/// An agent that leaves JSONL session logs on disk.
public protocol SessionLogSource {
    var agent: Agent { get }
    /// Log files that might be written to soon (recently modified ones).
    func discoverFiles(now: Date) -> [URL]
    func context(for file: URL) -> SessionLogContext
    /// Turns a line into an event, updating the context with any metadata it carries.
    func parse(line: Data, context: inout SessionLogContext) -> AgentEventKind?
}

/// Follows agents' session logs and turns new lines into events. Needs no agent configuration,
/// and it's how Turbo sees Codex and Cowork turns *start* (neither has a start hook).
public final class SessionLogTailer {
    public let source: SessionLogSource
    public var onEvent: (AgentEvent) -> Void = { _ in }
    /// Directory scans are the expensive part, so they happen less often than reads.
    public var rediscoverInterval: TimeInterval = 5

    private struct FileState {
        var offset: UInt64
        var context: SessionLogContext
        var partial = Data()
    }

    private var files: [String: FileState] = [:]
    private var watched: [URL] = []
    private var lastDiscovery: Date?
    private var startedAt: Date?
    private let fileManager = FileManager.default

    public init(source: SessionLogSource) {
        self.source = source
    }

    /// Call about once a second. The first call only records where existing files end, so
    /// history isn't replayed as fresh events.
    public func poll(now: Date = Date()) {
        let startedAt = self.startedAt ?? now
        self.startedAt = startedAt
        if lastDiscovery.map({ now.timeIntervalSince($0) >= rediscoverInterval }) ?? true {
            watched = source.discoverFiles(now: now)
            lastDiscovery = now
        }
        for url in watched {
            let path = url.path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? UInt64 else { continue }

            if var state = files[path] {
                if size < state.offset {
                    state.offset = 0
                    state.partial = Data()
                }
                guard size > state.offset else {
                    files[path] = state
                    continue
                }
                read(path: path, state: &state, upTo: size, emit: true, now: now)
                files[path] = state
            } else {
                var state = FileState(offset: 0, context: source.context(for: url))
                // Only sessions born after we started replay from the top. Anything older (even
                // one that just woke up again) is read silently for metadata, so finished turns
                // from its history don't re-announce themselves.
                let created = attributes[.creationDate] as? Date
                let isNew = created.map { $0 >= startedAt.addingTimeInterval(-1) } ?? false
                read(path: path, state: &state, upTo: size, emit: isNew && now > startedAt, now: now)
                files[path] = state
            }
        }
    }

    private func read(path: String, state: inout FileState, upTo size: UInt64, emit: Bool, now: Date) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        // Don't slurp megabytes of history just to find a metadata line.
        let start = emit ? state.offset : 0
        let limit = emit ? size - start : min(size, 64 * 1024)
        handle.seek(toFileOffset: start)
        let chunk = handle.readData(ofLength: Int(limit))
        state.offset = emit ? start + UInt64(chunk.count) : size

        var buffer = emit ? state.partial + chunk : chunk
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            state.context.prompt = nil
            guard let kind = source.parse(line: line, context: &state.context), emit else { continue }
            let c = state.context
            onEvent(AgentEvent(
                agent: source.agent, sessionID: c.sessionID, cwd: c.cwd, kind: kind,
                hostAppBundleID: c.hostAppBundleID, title: c.title, prompt: c.prompt, date: now
            ))
        }
        state.partial = emit ? buffer : Data()
    }
}

// MARK: - Codex

/// ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl
public struct CodexRolloutSource: SessionLogSource {
    public let root: URL
    public var agent: Agent { .codex }

    public init(root: URL = CodexRolloutSource.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Today's and yesterday's day folders, in both local time and UTC since which one Codex
    /// uses is an implementation detail, plus the legacy flat layout.
    public func discoverFiles(now: Date) -> [URL] {
        var dirs: [URL] = [root]
        var seen = Set<String>()
        for timeZone in [TimeZone.current, TimeZone(identifier: "UTC")!] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            for dayOffset in [0, -1] {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                let c = calendar.dateComponents([.year, .month, .day], from: day)
                let rel = String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
                if seen.insert(rel).inserted { dirs.append(root.appendingPathComponent(rel, isDirectory: true)) }
            }
        }
        return dirs.flatMap { dir -> [URL] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }.map { dir.appendingPathComponent($0) }
        }
    }

    public func context(for file: URL) -> SessionLogContext {
        SessionLogContext(sessionID: Self.sessionID(fromFileName: file.lastPathComponent))
    }

    public func parse(line: Data, context: inout SessionLogContext) -> AgentEventKind? {
        switch EventParser.parseCodexRolloutLine(line) {
        case let .meta(id, cwd):
            if let id, !id.isEmpty { context.sessionID = id }
            if let cwd { context.cwd = cwd }
            return nil
        case let .event(kind):
            return kind
        case let .prompt(text):
            if context.title == nil { context.title = SessionNaming.title(fromPrompt: text) }
            context.prompt = text
            return .promptSubmitted
        case nil:
            return nil
        }
    }

    /// `rollout-2025-05-07T17-24-21-5973b6c0-94b8-487b-a530-2aeb6098ae0e.jsonl` → the trailing UUID.
    public static func sessionID(fromFileName name: String) -> String {
        let base = name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : name
        guard base.count >= 36 else { return base }
        let tail = String(base.suffix(36))
        return UUID(uuidString: tail) != nil ? tail.lowercased() : base
    }
}

// MARK: - Cowork

/// Claude Desktop's Cowork sessions:
/// ~/Library/Application Support/Claude/local-agent-mode-sessions/<account>/<space>/local_<id>/audit.jsonl
/// with a manifest beside each session folder at …/<space>/local_<id>.json (title, folders).
/// Cowork runs in a VM and doesn't fire Claude Code hooks, so its logs are the only signal.
public struct CoworkSessionSource: SessionLogSource {
    public let root: URL
    /// Only sessions touched this recently are watched.
    public var recentWindow: TimeInterval = 48 * 3600
    public var agent: Agent { .cowork }
    public static let desktopBundleID = "com.anthropic.claudefordesktop"

    public init(root: URL = CoworkSessionSource.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions", isDirectory: true)
    }

    public func discoverFiles(now: Date) -> [URL] {
        let fm = FileManager.default
        func subdirectories(_ url: URL) -> [URL] {
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            return names.filter { !$0.hasPrefix(".") }.map { url.appendingPathComponent($0, isDirectory: true) }.filter {
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
            }
        }
        var result: [URL] = []
        for account in subdirectories(root) {
            for space in subdirectories(account) {
                for session in subdirectories(space) where session.lastPathComponent.hasPrefix("local_") {
                    let audit = session.appendingPathComponent("audit.jsonl")
                    guard let modified = (try? fm.attributesOfItem(atPath: audit.path))?[.modificationDate] as? Date,
                          now.timeIntervalSince(modified) < recentWindow else { continue }
                    result.append(audit)
                }
            }
        }
        return result
    }

    public func context(for file: URL) -> SessionLogContext {
        let sessionDir = file.deletingLastPathComponent()
        let manifest = sessionDir.deletingLastPathComponent().appendingPathComponent(sessionDir.lastPathComponent + ".json")
        var context = SessionLogContext(sessionID: sessionDir.lastPathComponent, hostAppBundleID: Self.desktopBundleID, sidecar: manifest)
        Self.applyManifest(at: manifest, to: &context)
        return context
    }

    public func parse(line: Data, context: inout SessionLogContext) -> AgentEventKind? {
        switch EventParser.parseCoworkAuditLine(line) {
        case .meta:
            // The init line's cwd is the VM's sandbox path; the manifest's folders are what people recognize.
            return nil
        case let .event(kind):
            if context.title == nil, let manifest = context.sidecar { Self.applyManifest(at: manifest, to: &context) }
            return kind
        case let .prompt(text):
            context.prompt = text
            return .promptSubmitted
        case nil:
            return nil
        }
    }

    static func applyManifest(at url: URL, to context: inout SessionLogContext) {
        guard let data = try? Data(contentsOf: url), let obj = EventParser.jsonObject(data) else { return }
        if let title = obj["title"] as? String, !title.isEmpty { context.title = title }
        let folders = (obj["userSelectedFolders"] as? [String]) ?? (obj["folders"] as? [String]) ?? []
        if let folder = folders.first {
            context.cwd = folder
        } else if let cwd = obj["cwd"] as? String, !cwd.hasPrefix("/sessions") {
            context.cwd = cwd
        }
    }
}
