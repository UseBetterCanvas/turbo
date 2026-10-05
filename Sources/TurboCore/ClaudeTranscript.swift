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
    /// `imageDirectory` is where pasted images get saved so the chat can show them (nil skips them).
    public static func thread(atPath path: String, tailBytes: Int = 2 * 1024 * 1024, limit: Int = 80, imageDirectory: URL? = nil) -> [ThreadItem] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        var start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        // Back up to a record boundary so a prompt carrying a big pasted image is read whole
        // (up to 16 MB extra, the most an image record can be).
        let chunk: UInt64 = 256 * 1024
        var searched: UInt64 = 0
        boundary: while start > 0 && searched < 16 * 1024 * 1024 {
            let from = start > chunk ? start - chunk : 0
            handle.seek(toFileOffset: from)
            let bytes = handle.readData(ofLength: Int(start - from))
            if let newline = bytes.lastIndex(of: 0x0A) {
                start = from + UInt64(newline - bytes.startIndex) + 1
                break boundary
            }
            searched += start - from
            start = from
        }
        handle.seek(toFileOffset: start)
        return thread(inJSONL: handle.readDataToEndOfFile(), limit: limit, imageDirectory: imageDirectory)
    }

    public static func thread(inJSONL data: Data, limit: Int = 80, imageDirectory: URL? = nil) -> [ThreadItem] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var items: [ThreadItem] = []
        func add(_ kind: ThreadItem.Kind, _ text: String?, _ date: Date, images: [URL] = []) {
            // Consecutive text from one reply arrives as several lines: keep it as one bubble.
            if kind == .reply, let last = items.last, last.kind == .reply, let text {
                items[items.count - 1].text = (last.text.map { $0 + "\n\n" } ?? "") + text
                return
            }
            items.append(ThreadItem(id: items.count + 1, kind: kind, text: text, date: date, images: images))
        }
        // Transcripts can repeat a record (snapshots, resumes); count each one once.
        var seenRecords = Set<String>()
        var seenBlocks = Set<String>()
        for line in data.split(separator: 0x0A) {
            guard let obj = EventParser.jsonObject(Data(line)), obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            if let uuid = obj["uuid"] as? String, !seenRecords.insert(uuid).inserted { continue }
            let messageID = message["id"] as? String
            let date = (obj["timestamp"] as? String).flatMap(iso.date(from:)) ?? Date.distantPast
            let blocks = message["content"] as? [[String: Any]] ?? []
            switch obj["type"] as? String {
            case "user":
                guard isTypedPrompt(obj) else { continue }
                let text = (message["content"] as? String)
                    ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.hasPrefix("<command"), !trimmed.hasPrefix("<local-command") else { continue }
                let images = imageDirectory.map { promptImages(blocks, into: $0) } ?? []
                guard !trimmed.isEmpty || !images.isEmpty else { continue }
                add(.prompt, trimmed.isEmpty ? nil : trimmed, date, images: images)
            case "assistant":
                if let text = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    add(.reply, text, date)
                    continue
                }
                for (index, block) in blocks.enumerated() {
                    // The same block of the same message logged twice is one block.
                    if let messageID {
                        let key = "\(messageID)#\(index)#\(block["type"] as? String ?? "")#\((block["text"] as? String)?.prefix(64) ?? "")#\(block["id"] as? String ?? "")"
                        if !seenBlocks.insert(key).inserted { continue }
                    }
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

    /// Pasted images in a prompt, saved once each (named by content) so the chat can show them.
    static func promptImages(_ blocks: [[String: Any]], into directory: URL) -> [URL] {
        var urls: [URL] = []
        for block in blocks where block["type"] as? String == "image" {
            guard urls.count < 4, let source = block["source"] as? [String: Any],
                  source["type"] as? String == "base64", let base64 = source["data"] as? String,
                  base64.count < 14_000_000 else { continue }
            let ext: String
            switch source["media_type"] as? String {
            case "image/jpeg": ext = "jpg"
            case "image/gif": ext = "gif"
            case "image/webp": ext = "webp"
            default: ext = "png"
            }
            // FNV-1a over the encoded bytes: the same image always lands on the same file.
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in base64.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            let url = directory.appendingPathComponent(String(hash, radix: 16) + "." + ext)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard let data = Data(base64Encoded: base64) else { continue }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard (try? data.write(to: url)) != nil else { continue }
            }
            urls.append(url)
        }
        return urls
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
