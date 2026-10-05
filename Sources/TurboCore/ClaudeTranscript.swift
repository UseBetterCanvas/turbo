import Foundation

public enum ClaudeTranscript {
    /// The text of the last assistant message in a Claude Code transcript (JSONL), read from
    /// the tail of the file. Used as the "what did it cook" line when the Stop hook lacks one.
    /// `currentTurnOnly` stops at the last prompt you typed, so a new turn never shows the
    /// previous turn's reply as its latest.
    public static func lastAssistantText(atPath path: String, tailBytes: Int = 256 * 1024, currentTurnOnly: Bool = false) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        handle.seek(toFileOffset: start)
        return lastAssistantText(inJSONL: handle.readDataToEndOfFile(), currentTurnOnly: currentTurnOnly)
    }

    public static func lastAssistantText(inJSONL data: Data, currentTurnOnly: Bool = false) -> String? {
        let lines = data.split(separator: 0x0A)
        for line in lines.reversed() {
            guard let obj = EventParser.jsonObject(Data(line)) else { continue }
            if currentTurnOnly, isTypedPrompt(obj) { return nil }
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String, !text.isEmpty { return text }
            let parts = (message["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
            let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// The conversation in a Claude Code transcript: what you asked, each step, and each reply,
    /// oldest first. Reads only the tail of the file; subagent chatter is left out.
    public static func thread(atPath path: String, tailBytes: Int = 512 * 1024, limit: Int = 80) -> [ThreadItem] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        handle.seek(toFileOffset: start)
        return thread(inJSONL: handle.readDataToEndOfFile(), limit: limit)
    }

    public static func thread(inJSONL data: Data, limit: Int = 80) -> [ThreadItem] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var items: [ThreadItem] = []
        func add(_ kind: ThreadItem.Kind, _ text: String?, _ date: Date) {
            // Consecutive text from one reply arrives as several lines: keep it as one bubble.
            if kind == .reply, let last = items.last, last.kind == .reply, let text {
                items[items.count - 1].text = (last.text.map { $0 + "\n\n" } ?? "") + text
                return
            }
            items.append(ThreadItem(id: items.count + 1, kind: kind, text: text, date: date))
        }
        for line in data.split(separator: 0x0A) {
            guard let obj = EventParser.jsonObject(Data(line)), obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            let date = (obj["timestamp"] as? String).flatMap(iso.date(from:)) ?? Date.distantPast
            let blocks = message["content"] as? [[String: Any]] ?? []
            switch obj["type"] as? String {
            case "user":
                guard isTypedPrompt(obj) else { continue }
                let text = (message["content"] as? String)
                    ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("<command"), !trimmed.hasPrefix("<local-command") else { continue }
                add(.prompt, trimmed, date)
            case "assistant":
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            add(.reply, text, date)
                        }
                    case "tool_use":
                        let input = block["input"] as? [String: Any] ?? [:]
                        let detail = (input["description"] as? String)
                            ?? (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
                            ?? (input["pattern"] as? String)
                            ?? (input["url"] as? String)
                        add(.step(tool: block["name"] as? String), detail, date)
                    default:
                        continue
                    }
                }
            default:
                continue
            }
        }
        return Array(items.suffix(limit))
    }

    /// A user line that's something you typed, not a tool result Claude Code logs as "user".
    static func isTypedPrompt(_ obj: [String: Any]) -> Bool {
        guard obj["type"] as? String == "user", obj["isMeta"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return !blocks.isEmpty && !blocks.contains { $0["type"] as? String == "tool_result" }
    }
}

public enum Format {
    /// 75 → "1m 15s", 3700 → "1h 1m", 9 → "9s"
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// 75 → "1:15", 3700 → "1:01:40"
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// First meaningful line of a (possibly markdown) message, trimmed for a one-line UI.
    public static func snippet(_ text: String?, limit: Int = 140) -> String? {
        guard let text else { return nil }
        let line = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") }?
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*>-` "))
        guard let line, !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
