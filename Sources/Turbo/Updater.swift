import AppKit
import TurboCore

/// Keeps Turbo current: checks the `latest-build` release, downloads it, swaps the app in place
/// and relaunches. Apps that download their own updates don't trigger macOS's "could not verify"
/// prompt (that flag comes from browsers), so updating this way skips it.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case downloading
        case installing
        /// The repo is private and we have no GitHub sign-in to read it with.
        case needsAccess
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    /// The commit this build came from (stamped into Info.plist by bundle.sh).
    let installedCommit = Bundle.main.object(forInfoDictionaryKey: "TurboCommit") as? String

    private var loop: Task<Void, Never>?
    private var token: String?

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    func start() {
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    func check() async {
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .checking
        do {
            let data = try await fetch(UpdateInfo.releaseAPI, accept: "application/vnd.github+json")
            lastChecked = Date()
            guard let info = UpdateInfo.parse(release: data) else {
                state = .failed("Couldn't read the latest release.")
                return
            }
            state = info.isNewer(thanInstalled: installedCommit) ? .available(info) : .upToDate
        } catch UpdateError.noAccess {
            state = .needsAccess
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install() async {
        guard case let .available(info) = state else { return }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            state = .failed("Run Turbo from your Applications folder to update it.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            state = .failed("Turbo can't write to \(target.deletingLastPathComponent().path). Move it to Applications and try again.")
            return
        }

        state = .downloading
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("turbo-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zipData = try await fetch(UpdateInfo.assetAPI(id: info.assetID), accept: "application/octet-stream")
            let zip = work.appendingPathComponent("Turbo.zip")
            try zipData.write(to: zip)

            state = .installing
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let newApp = work.appendingPathComponent("Turbo.app")
            guard FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/Turbo").path) else {
                throw UpdateError.message("The download didn't contain Turbo.app.")
            }
            try relaunch(replacing: target, with: newApp, cleanup: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Networking

    enum UpdateError: LocalizedError {
        case noAccess
        case message(String)

        var errorDescription: String? {
            switch self {
            case .noAccess: return "No access to Turbo's releases."
            case let .message(text): return text
            }
        }
    }

    /// Tries without credentials first (works if the repo is public), then with the GitHub CLI's
    /// sign-in (works for a private repo).
    private func fetch(_ url: URL, accept: String) async throws -> Data {
        if let data = try await request(url, accept: accept, token: nil) { return data }
        if token == nil { token = await Self.githubCLIToken() }
        guard let token, let data = try await request(url, accept: accept, token: token) else {
            throw UpdateError.noAccess
        }
        return data
    }

    /// Returns nil for "not visible to this caller" (404/401/403), throws for anything else.
    private func request(_ url: URL, accept: String, token: String?) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Turbo", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request, delegate: StripAuthOnRedirect())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if [401, 403, 404].contains(status) { return nil }
        guard (200..<300).contains(status) else { throw UpdateError.message("GitHub answered \(status).") }
        return data
    }

    /// Asset downloads redirect to a signed storage URL that rejects our GitHub token.
    private final class StripAuthOnRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var request = request
            if request.url?.host != "api.github.com" { request.setValue(nil, forHTTPHeaderField: "Authorization") }
            completionHandler(request)
        }
    }

    private static func githubCLIToken() async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard case let .success(output) = CodexCloudPoller.runInLoginShell(
                #"PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; gh auth token"#, timeout: 10
            ), output.status == 0 else { return nil }
            let token = String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return token?.isEmpty == false ? token : nil
        }.value
    }

    // MARK: Install

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.message("\(tool) failed (\(process.terminationStatus)).") }
    }

    /// Hands off to a tiny script that waits for Turbo to quit, swaps the app and reopens it.
    private func relaunch(replacing target: URL, with newApp: URL, cleanup: URL) throws {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(target.path))
        /usr/bin/ditto \(q(newApp.path)) \(q(target.path))
        /usr/bin/xattr -dr com.apple.quarantine \(q(target.path)) 2>/dev/null
        /usr/bin/open \(q(target.path))
        rm -rf \(q(cleanup.path))
        """
        let scriptURL = cleanup.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }
}
