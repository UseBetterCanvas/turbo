import Foundation

/// How much of your Claude plan you've used, as the Claude desktop app records it in
/// `~/Library/Application Support/Claude/plan-usage-history.json`:
/// `{"version":2,"samples":[{"t":<ms>,"org":"…","u":{"fh":7,"sd":10}}]}`, where `fh` is the
/// 5-hour window and `sd` the 7-day window, in percent.
public struct PlanUsage: Equatable, Sendable {
    public var fiveHour: Int
    public var week: Int?
    public var recordedAt: Date

    public init(fiveHour: Int, week: Int?, recordedAt: Date) {
        self.fiveHour = fiveHour
        self.week = week
        self.recordedAt = recordedAt
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// The newest sample, or nil if the file isn't there or has nothing usable.
    public static func latest(in data: Data) -> PlanUsage? {
        guard let root = EventParser.jsonObject(data), let samples = root["samples"] as? [[String: Any]] else { return nil }
        let parsed: [PlanUsage] = samples.compactMap { sample in
            guard let u = sample["u"] as? [String: Any], let fh = number(u["fh"]) else { return nil }
            let ms = number(sample["t"]) ?? 0
            return PlanUsage(fiveHour: fh, week: number(u["sd"]), recordedAt: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        return parsed.max { $0.recordedAt < $1.recordedAt }
    }

    public static func load(from url: URL = defaultURL) -> PlanUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return latest(in: data)
    }

    /// Worth a heads-up: close to the 5-hour limit.
    public var isHigh: Bool { fiveHour >= 80 }

    private static func number(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d.rounded()) }
        return nil
    }
}
