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
        /// Turbo can't replace itself where it's installed (e.g. an admin-owned folder);
        /// the install command can, since it asks for a password.
        case manualInstall(String)
        /// macOS is running a quarantined copy from a temporary read-only spot
        /// ("App Translocation"). Clearing the quarantine flag and reopening fixes it.
        case translocated
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    /// The commit and CI build number this build came from (stamped into Info.plist by
    /// bundle.sh). Local builds have no build number and never get update prompts.
    let installedCommit = Bundle.main.object(forInfoDictionaryKey: "TurboCommit") as? String
    let installedBuild = (Bundle.main.object(forInfoDictionaryKey: "TurboBuild") as? String).flatMap(Int.init)

    /// The last failed install attempt, shown on the board with a retry.
    @Published private(set) var installError: String?

    /// Asked before installing on its own: true when it's a good moment (nothing cooking).
    var autoInstall: (() -> Bool)?

    private var loop: Task<Void, Never>?
    private var token: String?
    private var checking = false

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    func start() {
        loop?.cancel()
        // Running from macOS's temporary copy: say so up front, since updates can't land.
        if Self.isTranslocated { state = .translocated }
        loop = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            var lastCheck = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                if Date().timeIntervalSince(lastCheck) >= 3600 {
                    lastCheck = Date()
                    await self.check()
                }
                // Found one? Install it the next quiet moment.
                if self.updateAvailable, self.installError == nil, self.autoInstall?() == true {
                    await self.install()
                }
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            }
        }
    }

    private var busyInstalling: Bool {
        switch state {
        case .downloading, .installing: return true
        default: return false
        }
    }

    func check() async {
        // One check at a time, and never while an install is under way.
        guard !checking, !busyInstalling else { return }
        checking = true
        defer { checking = false }
        state = .checking
        let result: State
        do {
            let data = try await fetch(UpdateInfo.releaseAPI, accept: "application/vnd.github+json")
            lastChecked = Date()
            if let info = UpdateInfo.parse(release: data) {
                result = info.isNewer(thanInstalledBuild: installedBuild, commit: installedCommit) ? .available(info) : .upToDate
            } else {
                result = .failed("Couldn't read the latest release.")
            }
        } catch UpdateError.noAccess {
            result = .needsAccess
        } catch {
            result = .failed(error.localizedDescription)
        }
        if !busyInstalling { state = result }
    }

    func install() async {
        guard case let .available(info) = state else { return }
        installError = nil
        let target = Bundle.main.bundleURL
        if Self.isTranslocated {
            state = .translocated
            return
        }
        guard target.pathExtension == "app" else {
            fail("Run Turbo from your Applications folder to update it.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            state = .manualInstall("Turbo can't replace itself in \(target.deletingLastPathComponent().path). Paste the install command in Terminal. It asks for your password.")
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
            fail(error.localizedDescription)
        }
    }

    /// "Try Again" after a failed install: refresh what's available, then install it.
    func retryInstall() async {
        installError = nil
        await check()
        await install()
    }

    /// True when macOS is running Turbo from its temporary App Translocation copy.
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// Where the real copy most likely lives.
    static var installedAppURL: URL {
        URL(fileURLWithPath: "/Applications/Turbo.app")
    }

    /// Clears the quarantine flag on the installed copy and reopens it from there, so updates
    /// can replace it. Falls back to the install command if Turbo isn't in Applications.
    func fixTranslocation() {
        let app = Self.installedAppURL
        guard FileManager.default.fileExists(atPath: app.path) else {
            state = .manualInstall("Move Turbo into your Applications folder, then reopen it. Or paste the install command in Terminal.")
            return
        }
        do {
            try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        } catch {
            state = .manualInstall("Couldn't clear macOS's download flag on Turbo. Paste the install command in Terminal to reinstall it.")
            return
        }
        // Reopen from Applications once this copy has quit.
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \(CodexCloudPoller.shellQuote(app.path))"]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func fail(_ message: String) {
        installError = message
        state = .failed(message)
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
        if let token, let data = try await request(url, accept: accept, token: token) { return data }
        // The cached token may have expired or been replaced by a fresh `gh auth login`.
        token = await Self.githubCLIToken()
        if let token, let data = try await request(url, accept: accept, token: token) { return data }
        throw UpdateError.noAccess
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

    /// Hands off to a tiny script that waits for Turbo to quit, then swaps the app in safely:
    /// the new copy is staged beside the old one, and the old app is only removed once the new
    /// one is fully in place. Any failure puts the old app back and reopens it.
    private func relaunch(replacing target: URL, with newApp: URL, cleanup: URL) throws {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let pid = ProcessInfo.processInfo.processIdentifier
        let staged = target.path + ".update"
        let backup = target.path + ".previous"
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(staged)) \(q(backup))
        if /usr/bin/ditto \(q(newApp.path)) \(q(staged)) \\
           && [ -x \(q(staged + "/Contents/MacOS/Turbo")) ] \\
           && mv \(q(target.path)) \(q(backup)) \\
           && mv \(q(staged)) \(q(target.path)); then
          rm -rf \(q(backup))
          /usr/bin/xattr -dr com.apple.quarantine \(q(target.path)) 2>/dev/null
        else
          rm -rf \(q(staged))
          [ -d \(q(backup)) ] && [ ! -d \(q(target.path)) ] && mv \(q(backup)) \(q(target.path))
        fi
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
