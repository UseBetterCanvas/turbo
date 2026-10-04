import Foundation

/// Reads the `latest-build` GitHub release to tell whether a newer Turbo is out.
/// CI writes "Built from main @ <sha7>" into the release notes; the app knows its own commit.
public struct UpdateInfo: Equatable, Sendable {
    public var commit: String
    public var assetID: Int
    public var assetSize: Int
    public var publishedAt: String?

    public static let releaseAPI = URL(string: "https://api.github.com/repos/UseBetterCanvas/turbo/releases/tags/latest-build")!

    public static func assetAPI(id: Int) -> URL {
        URL(string: "https://api.github.com/repos/UseBetterCanvas/turbo/releases/assets/\(id)")!
    }

    /// Parses the GitHub release JSON. Returns nil if there's no Turbo.zip or no commit in the notes.
    public static func parse(release data: Data) -> UpdateInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let body = obj["body"] as? String,
              let commit = commit(inNotes: body),
              let assets = obj["assets"] as? [[String: Any]],
              let zip = assets.first(where: { $0["name"] as? String == "Turbo.zip" }),
              let id = zip["id"] as? Int else { return nil }
        return UpdateInfo(commit: commit, assetID: id, assetSize: zip["size"] as? Int ?? 0, publishedAt: obj["published_at"] as? String)
    }

    /// "Built from main @ 4061f61." → "4061f61"
    static func commit(inNotes notes: String) -> String? {
        guard let range = notes.range(of: #"@ ([0-9a-f]{7,40})"#, options: .regularExpression) else { return nil }
        return String(notes[range].dropFirst(2))
    }

    /// True when the release was built from a different commit than the running app. Unknown
    /// local builds ("dev") never nag.
    public func isNewer(thanInstalled installed: String?) -> Bool {
        guard let installed, installed.count >= 7, installed != "dev" else { return false }
        let a = installed.lowercased(), b = commit.lowercased()
        return !(a.hasPrefix(b) || b.hasPrefix(a))
    }
}
