import Foundation

/// Just enough HTTP/1.1 to accept the `curl` POSTs that hooks send to 127.0.0.1.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data
}

public enum HTTPParseResult: Equatable {
    case incomplete
    case invalid
    case complete(HTTPRequest)
}

public enum HTTPParser {
    public static let maxSize = 1 << 20

    public static func parse(_ data: Data) -> HTTPParseResult {
        if data.count > maxSize { return .invalid }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0 else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }

        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: Data(body)
        ))
    }
}

public enum EventRouter {
    /// Maps `POST /hook/claude` and `POST /hook/codex` to agent events.
    public static func event(for request: HTTPRequest, now: Date = Date()) -> AgentEvent? {
        guard request.method == "POST" else { return nil }
        var event: AgentEvent?
        switch request.path {
        case "/hook/claude", HookInstaller.gatePath: event = EventParser.parseClaudeHook(request.body, now: now)
        case "/hook/codex": event = EventParser.parseCodexNotify(request.body, now: now)
        default: return nil
        }
        event?.hostAppBundleID = HostApp.bundleID(app: request.query["app"], termProgram: request.query["term"])
        return event
    }
}

public enum HostApp {
    /// macOS exports `__CFBundleIdentifier` to processes launched from an app, which is the
    /// best signal. `TERM_PROGRAM` is the fallback for shells that scrub it.
    public static func bundleID(app: String?, termProgram: String?) -> String? {
        if let app, !app.isEmpty { return app }
        switch termProgram {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "vscode": return "com.microsoft.VSCode"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WezTerm": return "com.github.wez.wezterm"
        case "Hyper": return "co.zeit.hyper"
        case "zed": return "dev.zed.Zed"
        default: return nil
        }
    }

    /// Terminals and editors a coding agent commonly runs in.
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "com.github.wez.wezterm", "co.zeit.hyper", "dev.zed.Zed",
        "net.kovidgoyal.kitty", "io.alacritty", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]

    public static func isTerminal(bundleID: String?) -> Bool {
        bundleID.map(terminals.contains) ?? false
    }
}

/// Sessions you asked to stop. The next `PreToolUse` hook from one of them gets told to stop.
/// Read on the server's queue, written on the main actor, hence the lock.
public final class StopRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    public init() {}

    public func request(_ sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        ids.insert(sessionID)
    }

    public func cancel(_ sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        ids.remove(sessionID)
    }

    public func contains(_ sessionID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(sessionID)
    }

    /// True once per request: the gate that sees it stops the session.
    public func consume(_ sessionID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.remove(sessionID) != nil
    }

    /// What the gate hook prints: stop, or carry on.
    public static func gateResponse(stop: Bool) -> String {
        stop ? #"{"continue":false,"stopReason":"Stopped from Turbo"}"# : ""
    }
}

/// Messages you've typed for a session, waiting for it to finish its turn. When Claude Code's
/// Stop hook asks the gate, the oldest one is handed over and Claude carries on with it.
public final class ReplyQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [String: [String]] = [:]

    public init() {}

    public func enqueue(_ text: String, for sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        queued[sessionID, default: []].append(text)
    }

    /// Hands over the next reply, once.
    public func take(_ sessionID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var list = queued[sessionID], !list.isEmpty else { return nil }
        let first = list.removeFirst()
        queued[sessionID] = list.isEmpty ? nil : list
        return first
    }

    public func pending(_ sessionID: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return queued[sessionID] ?? []
    }

    public func clear(_ sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        queued[sessionID] = nil
    }

    /// What the Stop hook prints to keep Claude going with your message.
    public static func continueResponse(_ text: String) -> String {
        let object: [String: Any] = ["decision": "block", "reason": text]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Whether a command was a test run, and whether it passed, judged from its output. Used to
/// say "tests passing" or "tests failing" on a finished session.
public enum TestSignal {
    static let runners = [
        "npm test", "npm run test", "pnpm test", "pnpm run test", "yarn test", "bun test", "npx jest", "jest",
        "vitest", "pytest", "python -m pytest", "go test", "cargo test", "swift test", "xcodebuild test",
        "rspec", "bundle exec rspec", "rails test", "mix test", "phpunit", "gradle test", "./gradlew test",
        "mvn test", "dotnet test", "make test", "deno test", "playwright test",
    ]

    /// nil when the command isn't a test run.
    public static func passed(command: String, output: String, exitCode: Int? = nil) -> Bool? {
        let c = command.lowercased()
        guard runners.contains(where: { c.contains($0) }) else { return nil }
        if let exitCode { return exitCode == 0 }
        let o = output.lowercased()
        let failed = [" failed", "failures:", "✗", "✕", "error:", "tests failed", "failing", "fail "].contains { o.contains($0) }
            && !o.contains("0 failed") && !o.contains("0 failures") && !o.contains("failed: 0")
        return !failed
    }
}

/// What a turn changed in the repo: counts, and (when sharing is on, or for local sessions) the files.
public struct ChangeSummary: Equatable, Sendable {
    public var files: Int
    public var additions: Int
    public var deletions: Int
    public var paths: [String]

    public init(files: Int, additions: Int, deletions: Int, paths: [String] = []) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
        self.paths = paths
    }

    /// From `git diff --numstat` output.
    public static func parse(numstat: String) -> ChangeSummary {
        var files = 0, add = 0, del = 0
        var paths: [String] = []
        for line in numstat.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            files += 1
            add += Int(parts[0]) ?? 0
            del += Int(parts[1]) ?? 0
            paths.append(String(parts[2]))
        }
        return ChangeSummary(files: files, additions: add, deletions: del, paths: paths)
    }

    init?(json: [String: Any]) {
        guard let files = json["files"] as? Int else { return nil }
        self.init(files: files, additions: json["add"] as? Int ?? 0, deletions: json["del"] as? Int ?? 0, paths: json["paths"] as? [String] ?? [])
    }
}

