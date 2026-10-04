import TurboCore
import Foundation

/// Subscribes to the cloud relay channel (an ntfy JSON stream) and turns each message into an
/// agent event. Reconnects with backoff and resumes from the last message it saw.
final class RelayListener: NSObject, URLSessionDataDelegate {
    enum State: Equatable {
        case off
        case connecting
        case listening
        case retrying(String)
    }

    var onEvent: (@MainActor (AgentEvent) -> Void)?
    var onState: (@MainActor (State) -> Void)?
    /// Fires for every relay message, even ones that aren't events (like the self-test).
    var onMessage: (@MainActor () -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var channel: String?
    private var lastID: String?
    private var retryDelay: TimeInterval = 1
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    func start(channel: String) {
        stop()
        self.channel = channel
        retryDelay = 1
        connect()
    }

    func stop() {
        channel = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        publish(.off)
    }

    /// Posts a message to our own channel; seeing it come back proves the Mac side works.
    func sendTestPing() {
        guard let channel else { return }
        var request = URLRequest(url: CloudRelay.publishURL(channel: channel))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"turbo":"test"}"#.utf8)
        URLSession.shared.dataTask(with: request).resume()
    }

    private func connect() {
        guard let channel else { return }
        publish(.connecting)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120   // ntfy sends a keepalive every ~45s
        config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        buffer = Data()
        let task = session.dataTask(with: CloudRelay.subscribeURL(channel: channel, since: lastID))
        self.task = task
        task.resume()
    }

    private func publish(_ state: State) {
        guard let onState else { return }
        Task { @MainActor in onState(state) }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            retryDelay = 1
            publish(.listening)
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let parsed = EventParser.parseRelayLine(line) else { continue }
            lastID = parsed.id
            if let onMessage { Task { @MainActor in onMessage() } }
            if let event = parsed.event, let onEvent {
                Task { @MainActor in onEvent(event) }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard channel != nil, session === self.session else { return }
        let reason = error?.localizedDescription ?? "Connection closed"
        publish(.retrying(reason))
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        queue.addOperation { [weak self] in
            Thread.sleep(forTimeInterval: delay)
            guard let self, self.channel != nil, session === self.session else { return }
            self.connect()
        }
    }
}
