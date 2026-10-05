import TurboCore
import Foundation
import Network

/// A tiny loopback-only HTTP server that receives the hook POSTs from Claude Code and Codex.
final class EventServer {
    var onRequest: (@MainActor (HTTPRequest) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    /// A Claude Code permission prompt. Call the responder exactly once with the hook's stdout
    /// (allow/deny JSON, or "" to let Claude Code ask in the terminal as usual).
    var onPermission: (@MainActor (HTTPRequest, @escaping @Sendable (String) -> Void) -> Void)?

    /// Sessions you asked to stop. The gate hook checks it before every tool call.
    var stops: StopRequests?
    /// A gate told a session to stop.
    var onStopped: (@MainActor (String) -> Void)?
    /// Replies you've typed, handed to Claude when its turn ends.
    var replies: ReplyQueue?
    /// A Stop hook took one of your replies, so the session carries on with it.
    var onReplied: (@MainActor (String, String) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "turbo.event-server")

    enum ServerError: Error {
        case badPort
    }

    func start(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ServerError.badPort }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case let .failed(error) = state, let handler = self?.onFailure else { return }
            Task { @MainActor in
                handler("Event server stopped: \(error.localizedDescription). Is another copy of Turbo running?")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch HTTPParser.parse(buffer) {
            case let .complete(request):
                if request.path == "/health" {
                    self.respond(on: connection, status: "200 OK", body: "turbo")
                    return
                }
                if request.path == "/hook/claude/permission" {
                    self.holdForDecision(request, on: connection)
                    return
                }
                if request.path == HookInstaller.gatePath {
                    // Answer right away: "" carries on, a stop answer ends the turn, and at the
                    // end of a turn a waiting reply keeps Claude going with it.
                    let body = EventParser.jsonObject(request.body) ?? [:]
                    let id = body["session_id"] as? String ?? ""
                    // Stop always wins over a waiting reply.
                    if self.stops?.consume(id) == true {
                        self.respond(on: connection, status: "200 OK", body: StopRequests.gateResponse(stop: true), contentType: "application/json")
                        if let stopped = self.onStopped { Task { @MainActor in stopped(id) } }
                        return
                    }
                    if body["hook_event_name"] as? String == "Stop", let reply = self.replies?.take(id) {
                        self.respond(on: connection, status: "200 OK", body: ReplyQueue.continueResponse(reply), contentType: "application/json")
                        // Not the end of the turn after all: report the new instruction instead.
                        if let replied = self.onReplied { Task { @MainActor in replied(id, reply) } }
                        return
                    }
                    self.respond(on: connection, status: "200 OK", body: StopRequests.gateResponse(stop: false), contentType: "application/json")
                } else {
                    self.respond(on: connection, status: "200 OK", body: "ok")
                }
                if let handler = self.onRequest {
                    Task { @MainActor in handler(request) }
                }
            case .incomplete where error == nil && !isComplete:
                self.receive(on: connection, buffer: buffer)
            default:
                self.respond(on: connection, status: "400 Bad Request", body: "bad request")
            }
        }
    }

    /// Keeps the hook's request open until the user answers in Turbo, with a backstop so the
    /// hook (and Claude Code) never waits longer than the hook's own timeout.
    private func holdForDecision(_ request: HTTPRequest, on connection: NWConnection) {
        let once = Once()
        let respond: @Sendable (String) -> Void = { [weak self] body in
            guard once.claim() else { return }
            self?.respond(on: connection, status: "200 OK", body: body, contentType: "application/json")
        }
        queue.asyncAfter(deadline: .now() + 70) { respond("") }
        guard let handler = onPermission else { respond(""); return }
        Task { @MainActor in handler(request, respond) }
    }

    private func respond(on connection: NWConnection, status: String, body: String, contentType: String = "text/plain") {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// True the first time `claim()` is called, false after; safe from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
