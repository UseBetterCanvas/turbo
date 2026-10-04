import AppKit
import TurboCore
import Foundation

/// Reads and writes the agents' config files. The pure edit logic lives in `HookInstaller`.
enum Integrations {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }

    enum CodexStatus: Equatable {
        case connected
        case notConnected
        case conflict(existing: String)
    }

    static let installCommand = #"gh api repos/UseBetterCanvas/turbo/contents/scripts/install.sh -H "Accept: application/vnd.github.raw" > /tmp/turbo-install.sh && bash /tmp/turbo-install.sh"#

    /// Codex has been used on this Mac.
    static var isCodexPresent: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
    }

    /// The Claude desktop app (home of Cowork) is installed, or Cowork has left sessions behind.
    static var isCoworkPresent: Bool {
        FileManager.default.fileExists(atPath: CoworkSessionSource.defaultRoot.path)
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: CoworkSessionSource.desktopBundleID) != nil
    }

    /// The PermissionRequest hook that lets you Allow / Deny from Turbo.
    static var isClaudeApprovalInstalled: Bool {
        HookInstaller.isClaudeApprovalInstalled(try? Data(contentsOf: claudeSettingsURL))
    }

    static var isClaudeInstalled: Bool {
        HookInstaller.isClaudeInstalled(try? Data(contentsOf: claudeSettingsURL))
    }

    static func installClaude() throws {
        let current = try? Data(contentsOf: claudeSettingsURL)
        let updated = try HookInstaller.installClaude(into: current)
        try write(updated, to: claudeSettingsURL, backingUp: current)
    }

    static func uninstallClaude() throws {
        guard let current = try? Data(contentsOf: claudeSettingsURL) else { return }
        try write(try HookInstaller.uninstallClaude(from: current), to: claudeSettingsURL, backingUp: current)
    }

    static var codexStatus: CodexStatus {
        let toml = try? String(contentsOf: codexConfigURL, encoding: .utf8)
        switch HookInstaller.installCodex(into: toml) {
        case .alreadyInstalled: return .connected
        case .installed: return .notConnected
        case let .conflict(existing): return .conflict(existing: existing)
        }
    }

    @discardableResult
    static func installCodex() throws -> HookInstaller.CodexInstallResult {
        let current = try? String(contentsOf: codexConfigURL, encoding: .utf8)
        let result = HookInstaller.installCodex(into: current)
        if case let .installed(updated) = result {
            try write(Data(updated.utf8), to: codexConfigURL, backingUp: current.map { Data($0.utf8) })
        }
        return result
    }

    static func uninstallCodex() throws {
        guard let current = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return }
        let updated = HookInstaller.uninstallCodex(from: current)
        guard updated != current else { return }
        try write(Data(updated.utf8), to: codexConfigURL, backingUp: Data(current.utf8))
    }

    /// Keeps the very first original around as `<file>.turbo-backup` before touching anything.
    private static func write(_ data: Data, to link: URL, backingUp original: Data?) throws {
        let fm = FileManager.default
        // Write through symlinks (dotfile repos) instead of replacing them.
        let url = link.resolvingSymlinksInPath()
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("turbo-backup")
        if let original, !fm.fileExists(atPath: backup.path) {
            try original.write(to: backup, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}
