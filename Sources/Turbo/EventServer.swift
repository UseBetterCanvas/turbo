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
                self.respond(on: connection, status: "200 OK", body: "ok")
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
