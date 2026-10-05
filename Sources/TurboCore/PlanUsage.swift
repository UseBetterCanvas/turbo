import Foundation

/// How much of your Claude plan you've used, as the Claude desktop app records it in
/// `~/Library/Application Support/Claude/plan-usage-history.json`:
/// `{"version":2,"samples":[{"t":<ms>,"org":"…","u":{"fh":7,"sd":10}}]}`, where `fh` is the
/// 5-hour window and `sd` the 7-day window, in percent.
public struct PlanUsage: Equatable, Sendable {
    public var fiveHour: Int
    public var week: Int?
    public var recordedAt: Date
    /// About when each window resets, worked out from the history (the app doesn't store it).
    public var sessionResetsAt: Date?
    public var weekResetsAt: Date?
    /// The 5-hour window's readings so far, oldest first, for a small trend line.
    public var sessionTrend: [Int] = []

    public init(fiveHour: Int, week: Int?, recordedAt: Date, sessionResetsAt: Date? = nil, weekResetsAt: Date? = nil, sessionTrend: [Int] = []) {
        self.fiveHour = fiveHour
        self.week = week
        self.recordedAt = recordedAt
        self.sessionResetsAt = sessionResetsAt
        self.weekResetsAt = weekResetsAt
        self.sessionTrend = sessionTrend
    }

    static let sessionWindow: TimeInterval = 5 * 3600
    static let weekWindow: TimeInterval = 7 * 86_400

    /// A window starts with the first usage after its count last fell (the previous window
    /// reset), and resets one window-length later. With no reset in the history there's no
    /// telling when the window began, so no estimate.
    static func windowStart(_ points: [(Date, Int)]) -> Date? {
        guard points.count > 1 else { return nil }
        var startIndex: Int?
        for i in 1..<points.count where points[i].1 < points[i - 1].1 {
            startIndex = i
        }
        guard let startIndex else { return nil }
        // The first reading in this window that shows any use.
        return points[startIndex...].first { $0.1 > 0 }?.0
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
        }.sorted { $0.recordedAt < $1.recordedAt }
        guard var latest = parsed.last else { return nil }

        let session = parsed.map { ($0.recordedAt, $0.fiveHour) }
        if let start = windowStart(session) {
            let reset = start.addingTimeInterval(sessionWindow)
            if reset > latest.recordedAt { latest.sessionResetsAt = reset }
            latest.sessionTrend = parsed.filter { $0.recordedAt >= start }.map(\.fiveHour)
        }
        let week = parsed.compactMap { p in p.week.map { (p.recordedAt, $0) } }
        if let start = windowStart(week) {
            let reset = start.addingTimeInterval(weekWindow)
            if reset > latest.recordedAt { latest.weekResetsAt = reset }
        }
        return latest
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
