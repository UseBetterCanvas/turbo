import Foundation
import TurboCore

/// Polls `codex cloud list --json` through the user's login shell (so Homebrew and npm installs
/// are on PATH) and feeds status changes into the session store.
final class CodexCloudPoller {
    enum State: Equatable {
        case off
        case checking
        /// Watching; the count is how many cloud tasks the last poll returned.
        case watching(Int)
        case notInstalled
        case notSignedIn
        case failed(String)
    }

    var onEvents: (@MainActor ([AgentEvent]) -> Void)?
    var onState: (@MainActor (State) -> Void)?

    private let tracker = CodexCloud.Tracker()
    private let queue = DispatchQueue(label: "turbo.codex-cloud")
    private var timer: DispatchSourceTimer?
    private var running = false

    func start(every interval: TimeInterval = 20) {
        stop()
        publish(.checking)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        publish(.off)
    }

    /// Checks right away (used by the "Check Now" button).
    func pollNow() {
        queue.async { [weak self] in self?.poll() }
    }

    private func poll() {
        guard !running else { return }
        running = true
        defer { running = false }

        let result = Self.runInLoginShell(Self.findCodex + "codex cloud list --json --limit 20", timeout: 20)
        switch result {
        case let .success(output):
            guard let tasks = CodexCloud.parseList(output.stdout) else {
                publish(Self.classify(output))
                return
            }
            let events = tracker.update(with: tasks)
            publish(.watching(tasks.count))
            if !events.isEmpty, let onEvents {
                Task { @MainActor in onEvents(events) }
            }
        case let .failure(message):
            publish(.failed(message))
        }
    }

    private static func classify(_ output: ShellOutput) -> State {
        let text = (String(data: output.stderr, encoding: .utf8) ?? "") + (String(data: output.stdout, encoding: .utf8) ?? "")
        let lower = text.lowercased()
        if output.status == 127 || lower.contains("command not found") || lower.contains("codex: not found") {
            return .notInstalled
        }
        if lower.contains("login") || lower.contains("log in") || lower.contains("sign in") || lower.contains("unauthorized") || lower.contains("401") {
            return .notSignedIn
        }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? "exit \(output.status)"
        return .failed(String(firstLine.prefix(140)))
    }

    private func publish(_ state: State) {
        guard let onState else { return }
        Task { @MainActor in onState(state) }
    }

    // MARK: Shell

    /// Login shells don't always load nvm or npm paths, so add the usual install spots.
    static let findCodex = #"PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$HOME/.volta/bin"; for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$PATH:$d"; done; export PATH; "#

    struct ShellOutput {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    enum ShellResult {
        case success(ShellOutput)
        case failure(String)
    }

    /// Runs a command in the user's login shell with a timeout.
    static func runInLoginShell(_ command: String, timeout: TimeInterval) -> ShellResult {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }
        // Read concurrently so a chatty process can't fill the pipe and stall.
        var stdout = Data()
        var stderr = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { stdout = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { stderr = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = DispatchTime.now() + timeout
        while process.isRunning {
            if DispatchTime.now() > deadline {
                process.terminate()
                return .failure("codex took too long to answer")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        _ = group.wait(timeout: .now() + 2)
        return .success(ShellOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr))
    }
}
