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

