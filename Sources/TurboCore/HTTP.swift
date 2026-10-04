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
        case "/hook/claude": event = EventParser.parseClaudeHook(request.body, now: now)
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
}
