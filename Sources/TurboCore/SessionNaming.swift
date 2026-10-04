import Foundation

/// Turns what we know about a session into a name a person recognizes: a short title from
/// the first thing it was asked, and the repo it runs in (unless the folder is an opaque id).
public enum SessionNaming {
    /// "Can you build the note style picker for the LMS?" → "Build the note style picker for…"
    public static func title(fromPrompt prompt: String?) -> String? {
        guard let prompt else { return nil }
        guard let line = prompt
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        // Codex and other agents prepend machine context as the first "user" message.
        if line.hasPrefix("<") || line.hasPrefix("# AGENTS.md") || line.hasPrefix("#") && line.lowercased().contains("instructions") { return nil }

        var text = line
        let filler = ["hey ", "hi ", "ok ", "okay ", "so ", "please ", "pls ", "plz ", "can you ", "can u ", "could you ",
                      "would you ", "i want you to ", "i need you to ", "i'd like you to ", "help me ", "lets ", "let's "]
        var stripped = true
        while stripped {
            stripped = false
            for word in filler where text.lowercased().hasPrefix(word) {
                text = String(text.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?:;"))
        guard !text.isEmpty else { return nil }

        let words = text.split(separator: " ")
        var title = words.prefix(6).joined(separator: " ")
        if title.count > 44 { title = String(title.prefix(43)).trimmingCharacters(in: .whitespaces) + "…" }
        else if words.count > 6 { title += "…" }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// The folder's name, or nil when it's an id nobody would recognize
    /// (`g-p-6781bfff…` for ChatGPT projects, UUIDs, hashes).
    public static func repoName(fromPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return isOpaque(name) ? nil : name
    }

    public static func isOpaque(_ name: String) -> Bool {
        var run = 0, longest = 0
        for c in name.lowercased() {
            run = c.isHexDigit ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest >= 16
    }
}
