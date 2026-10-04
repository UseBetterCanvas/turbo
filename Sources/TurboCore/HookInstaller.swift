import Foundation

/// Edits ~/.claude/settings.json and ~/.codex/config.toml so the agents report to the app.
/// Every entry Turbo adds carries `marker`, which is how it finds (and removes) its own.
public enum HookInstaller {
    public static let marker = "turbo-hook"
    public static let defaultPort = 47823

    public static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd",
    ]
    static let claudeToolEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    // MARK: Claude Code

    /// The hook command. Output is discarded because Claude adds a hook's stdout to the
    /// conversation for some events, and `|| true` keeps Claude happy when the app isn't running.
    public static func claudeCommand(port: Int = defaultPort) -> String {
        "curl -s -m 1 --noproxy '*' -X POST -H 'Content-Type: application/json' --data-binary @- "
            + "\"http://127.0.0.1:\(port)/hook/claude?app=${__CFBundleIdentifier:-}&term=${TERM_PROGRAM:-}\" "
            + ">/dev/null 2>&1 || true # \(marker)"
    }

    public enum InstallError: Error, Equatable {
        case notAJSONObject
        case unexpectedHooksShape
    }

    /// The permission hook prints Turbo's answer (allow/deny JSON) to stdout, so unlike the
    /// others its output is kept. If Turbo doesn't answer (not running, or it timed out), it
    /// prints nothing and Claude Code shows its normal prompt.
    public static func claudeApprovalCommand(port: Int = defaultPort) -> String {
        "curl -s -m 75 --noproxy '*' -X POST -H 'Content-Type: application/json' --data-binary @- "
            + "\"http://127.0.0.1:\(port)/hook/claude/permission?app=${__CFBundleIdentifier:-}&term=${TERM_PROGRAM:-}\" "
            + "2>/dev/null || true # \(marker)"
    }

    public static let approvalEvent = "PermissionRequest"

    public static func isClaudeApprovalInstalled(_ settings: Data?) -> Bool {
        guard let settings, let root = EventParser.jsonObject(settings),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return (hooks[approvalEvent] as? [[String: Any]])?.contains(where: isOurs) ?? false
    }

    public static func isClaudeInstalled(_ settings: Data?) -> Bool {
        guard let settings, let root = EventParser.jsonObject(settings),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return claudeEvents.allSatisfy { event in
            (hooks[event] as? [[String: Any]])?.contains(where: isOurs) ?? false
        }
    }

    public static func installClaude(into settings: Data?, port: Int = defaultPort) throws -> Data {
        var root = try parseRoot(settings)
        var hooks = try existingHooks(root)
        for event in claudeEvents {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            var group: [String: Any] = ["hooks": [["type": "command", "command": claudeCommand(port: port)]]]
            if claudeToolEvents.contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        // Approve from Turbo: a separate hook that waits for your answer.
        var approval = (hooks[approvalEvent] as? [[String: Any]] ?? []).filter { !isOurs($0) }
        approval.append(["matcher": "*", "hooks": [["type": "command", "command": claudeApprovalCommand(port: port), "timeout": 90]]])
        hooks[approvalEvent] = approval
        root["hooks"] = hooks
        return try serialize(root)
    }

    public static func uninstallClaude(from settings: Data?) throws -> Data {
        var root = try parseRoot(settings)
        var hooks = try existingHooks(root)
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap(strippingOurs)
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialize(root)
    }

    private static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return [:] }
        guard let root = EventParser.jsonObject(data) else { throw InstallError.notAJSONObject }
        return root
    }

    private static func existingHooks(_ root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw InstallError.unexpectedHooksShape }
        return hooks
    }

    private static func commands(in group: [String: Any]) -> [[String: Any]] {
        group["hooks"] as? [[String: Any]] ?? []
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        commands(in: group).contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    /// Removes our commands from a matcher group; drops the group if nothing else is left.
    private static func strippingOurs(_ group: [String: Any]) -> [String: Any]? {
        let kept = commands(in: group).filter { ($0["command"] as? String)?.contains(marker) != true }
        if kept.isEmpty { return nil }
        var copy = group
        copy["hooks"] = kept
        return copy
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    // MARK: Codex

    /// Codex runs `notify` with the event JSON appended as the last argument; under `sh -c`
    /// that lands in `$1` (the marker fills `$0`).
    public static func codexNotifyLine(port: Int = defaultPort) -> String {
        let script = "curl -s -m 1 --noproxy '*' -X POST -H 'Content-Type: application/json' --data-binary \\\"$1\\\" "
            + "\\\"http://127.0.0.1:\(port)/hook/codex?app=${__CFBundleIdentifier:-}&term=${TERM_PROGRAM:-}\\\" "
            + ">/dev/null 2>&1 || true"
        return "notify = [\"/bin/sh\", \"-c\", \"\(script)\", \"\(marker)\"]"
    }

    public enum CodexInstallResult: Equatable {
        case installed(String)
        case alreadyInstalled
        /// The user already has a `notify` program; Codex only allows one, so we leave it alone.
        case conflict(existing: String)
    }

    public static func isCodexInstalled(_ toml: String?) -> Bool {
        guard let toml, let line = topLevelNotify(in: toml) else { return false }
        return line.contains(marker)
    }

    public static func installCodex(into toml: String?, port: Int = defaultPort) -> CodexInstallResult {
        let toml = toml ?? ""
        if let existing = topLevelNotify(in: toml) {
            return existing.contains(marker) ? .alreadyInstalled : .conflict(existing: existing)
        }
        // Top-level keys must come before the first [table], so prepend.
        let header = "# Added by Turbo: ping the Dynamic Island when a turn finishes.\n\(codexNotifyLine(port: port))\n"
        return .installed(toml.isEmpty ? header : header + "\n" + toml)
    }

    public static func uninstallCodex(from toml: String) -> String {
        var out: [Substring] = []
        var dropNextBlank = false
        for line in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# Added by Turbo") { continue }
            if line.range(of: #"^\s*notify\s*="#, options: .regularExpression) != nil, line.contains(marker) {
                dropNextBlank = true
                continue
            }
            if dropNextBlank, line.trimmingCharacters(in: .whitespaces).isEmpty {
                dropNextBlank = false
                continue
            }
            dropNextBlank = false
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// The `notify = …` statement before the first table header, if any (may span lines).
    static func topLevelNotify(in toml: String) -> String? {
        let lines = toml.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            guard trimmed.range(of: #"^notify\s*="#, options: .regularExpression) != nil else { continue }
            var statement = line
            var depth = bracketDepth(line)
            var next = index + 1
            while depth > 0, next < lines.count {
                statement += "\n" + lines[next]
                depth += bracketDepth(lines[next])
                next += 1
            }
            return statement
        }
        return nil
    }

    private static func bracketDepth(_ line: String) -> Int {
        var depth = 0
        var inString = false
        var previous: Character = " "
        for ch in line {
            if ch == "\"" && previous != "\\" { inString.toggle() }
            if !inString {
                if ch == "[" { depth += 1 }
                if ch == "]" { depth -= 1 }
                if ch == "#" { break }
            }
            previous = ch
        }
        return depth
    }

    // MARK: Permission rules

    /// Adds an allow rule to a Claude Code settings file (`.claude/settings.local.json` in a
    /// project), keeping everything else in it.
    public static func addingAllowRule(_ rule: String, to settings: Data?) throws -> Data {
        var root = try parseRoot(settings)
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        if !allow.contains(rule) { allow.append(rule) }
        permissions["allow"] = allow
        root["permissions"] = permissions
        return try serialize(root)
    }
}
