import Foundation

/// Reads the `latest-build` GitHub release to tell whether a newer Turbo is out.
/// CI writes "Built from main @ <sha7> (build <N>)" into the release notes; the app knows its own
/// build number, so only a strictly newer CI build counts as an update.
public struct UpdateInfo: Equatable, Sendable {
    public var commit: String
    /// CI run number of the release build; nil for releases made before builds were numbered.
    public var build: Int?
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
        return UpdateInfo(commit: commit, build: build(inNotes: body), assetID: id, assetSize: zip["size"] as? Int ?? 0, publishedAt: obj["published_at"] as? String)
    }

    /// "(build 42)" → 42
    static func build(inNotes notes: String) -> Int? {
        guard let range = notes.range(of: #"\(build [0-9]+\)"#, options: .regularExpression) else { return nil }
        return Int(notes[range].dropFirst(7).dropLast())
    }

    /// "Built from main @ 4061f61." → "4061f61"
    static func commit(inNotes notes: String) -> String? {
        guard let range = notes.range(of: #"@ ([0-9a-f]{7,40})"#, options: .regularExpression) else { return nil }
        return String(notes[range].dropFirst(2))
    }

    /// True only for a strictly newer CI build than the one running. Local builds (no build
    /// number) are never offered an update, so a newer branch build can't be "downgraded".
    public func isNewer(thanInstalledBuild installedBuild: Int?, commit installedCommit: String?) -> Bool {
        guard let installedBuild, let build, build > installedBuild else { return false }
        guard let installedCommit else { return true }
        let a = installedCommit.lowercased(), b = commit.lowercased()
        return !(a.hasPrefix(b) || b.hasPrefix(a))
    }
}
