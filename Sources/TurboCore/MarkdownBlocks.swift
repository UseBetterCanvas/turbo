import Foundation

/// Splits an agent's markdown reply into blocks a chat bubble can lay out:
/// headings, paragraphs, bullet and numbered lists, quotes and code.
/// Inline styling (bold, italic, `code`, links) is left in the text for the view.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is "•" for bullets or "1." style for numbered items. `depth` counts nesting.
    case listItem(marker: String, text: String, depth: Int)
    case quote(String)
    case code(String)
    case rule

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]? = nil

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(rawLine); continue }
            if trimmed.isEmpty { flushParagraph(); continue }

            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let depth = min(indent / 2, 3)

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(); blocks.append(.rule); continue
            }
            if let level = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
                flushParagraph()
                blocks.append(.listItem(marker: "•", text: String(trimmed.dropFirst(2)), depth: depth))
                continue
            }
            if let (number, rest) = numbered(trimmed) {
                flushParagraph()
                blocks.append(.listItem(marker: number + ".", text: rest, depth: depth))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case .quote(let previous)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(previous + " " + text)
                } else {
                    blocks.append(.quote(text))
                }
                continue
            }
            // A wrapped line continues the list item above it.
            if paragraph.isEmpty, indent > 0, case .listItem(let marker, let text, let d)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, text: text + " " + trimmed, depth: d)
                continue
            }
            paragraph.append(trimmed)
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let dot = rest.first, dot == "." || dot == ")", rest.dropFirst().first == " " else { return nil }
        return (String(digits), String(rest.dropFirst(2)))
    }
}
