import TurboCore
import Foundation

enum CookMode: String, CaseIterable, Identifiable {
    /// Just the Dynamic Island notifier.
    case island
    /// The island, plus a full-screen visualizer that plays while agents cook.
    case visualizer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .island: return "Island"
        case .visualizer: return "Visualizer"
        }
    }
}

enum VisualizerPreset: String, CaseIterable, Identifiable {
    case magnetosphere
    case ribbons
    case warp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .magnetosphere: return "Magnetosphere"
        case .ribbons: return "Ribbons"
        case .warp: return "Warp"
        }
    }

    var next: VisualizerPreset {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var previous: VisualizerPreset {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
    }
}

enum IslandPlacement: String, CaseIterable, Identifiable {
    /// In the notch, unless another notch app is running; then just below it.
    case automatic
    case notch
    case belowNotch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .notch: return "In the notch"
        case .belowNotch: return "Below the notch"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var mode: CookMode { didSet { defaults.set(mode.rawValue, forKey: Key.mode) } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Key.playSound) } }
    @Published var soundName: String { didSet { defaults.set(soundName, forKey: Key.soundName) } }
    /// Turns shorter than this finish quietly: the island just collapses, no celebration.
    @Published var minimumCookSeconds: Double { didSet { defaults.set(minimumCookSeconds, forKey: Key.minimumCookSeconds) } }
    /// How long the "done" card stays expanded.
    @Published var celebrateSeconds: Double { didSet { defaults.set(celebrateSeconds, forKey: Key.celebrateSeconds) } }
    @Published var returnToTerminalOnClick: Bool { didSet { defaults.set(returnToTerminalOnClick, forKey: Key.returnToTerminal) } }
    @Published var watchCodexSessions: Bool { didSet { defaults.set(watchCodexSessions, forKey: Key.watchCodex) } }
    @Published var watchCoworkSessions: Bool { didSet { defaults.set(watchCoworkSessions, forKey: Key.watchCowork) } }
    @Published var islandPlacement: IslandPlacement { didSet { defaults.set(islandPlacement.rawValue, forKey: Key.islandPlacement) } }
    @Published var cloudEnabled: Bool { didSet { defaults.set(cloudEnabled, forKey: Key.cloudEnabled) } }
    @Published var watchCodexCloud: Bool { didSet { defaults.set(watchCodexCloud, forKey: Key.watchCodexCloud) } }
    /// The private relay channel cloud sessions post to. Generated once; resettable.
    @Published var cloudChannel: String { didSet { defaults.set(cloudChannel, forKey: Key.cloudChannel) } }
    @Published var visualizerAutoOpen: Bool { didSet { defaults.set(visualizerAutoOpen, forKey: Key.visualizerAutoOpen) } }
    @Published var visualizerFullScreen: Bool { didSet { defaults.set(visualizerFullScreen, forKey: Key.visualizerFullScreen) } }
    @Published var visualizerAutoClose: Bool { didSet { defaults.set(visualizerAutoClose, forKey: Key.visualizerAutoClose) } }
    @Published var visualizerPreset: VisualizerPreset { didSet { defaults.set(visualizerPreset.rawValue, forKey: Key.visualizerPreset) } }

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

    static let sounds = ["Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Funk", "Blow", "Bottle", "Frog", "Morse", "Sosumi", "Tink"]

    private enum Key {
        static let mode = "mode"
        static let playSound = "playSound"
        static let soundName = "soundName"
        static let minimumCookSeconds = "minimumCookSeconds"
        static let celebrateSeconds = "celebrateSeconds"
        static let returnToTerminal = "returnToTerminalOnClick"
        static let watchCodex = "watchCodexSessions"
        static let watchCowork = "watchCoworkSessions"
        static let islandPlacement = "islandPlacement"
        static let cloudEnabled = "cloudEnabled"
        static let watchCodexCloud = "watchCodexCloud"
        static let cloudChannel = "cloudChannel"
        static let visualizerAutoOpen = "visualizerAutoOpen"
        static let visualizerFullScreen = "visualizerFullScreen"
        static let visualizerAutoClose = "visualizerAutoClose"
        static let visualizerPreset = "visualizerPreset"
        static let onboarded = "hasOnboarded"
    }

    init() {
        defaults.register(defaults: [
            Key.mode: CookMode.island.rawValue,
            Key.playSound: true,
            Key.soundName: "Glass",
            Key.minimumCookSeconds: 5.0,
            Key.celebrateSeconds: 6.0,
            Key.returnToTerminal: true,
            Key.watchCodex: true,
            Key.watchCowork: true,
            Key.islandPlacement: IslandPlacement.notch.rawValue,
            Key.cloudEnabled: false,
            Key.watchCodexCloud: true,
            Key.visualizerAutoOpen: false,
            Key.visualizerFullScreen: true,
            Key.visualizerAutoClose: true,
            Key.visualizerPreset: VisualizerPreset.magnetosphere.rawValue,
        ])
        mode = CookMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .island
        playSound = defaults.bool(forKey: Key.playSound)
        soundName = defaults.string(forKey: Key.soundName) ?? "Glass"
        minimumCookSeconds = defaults.double(forKey: Key.minimumCookSeconds)
        celebrateSeconds = defaults.double(forKey: Key.celebrateSeconds)
        returnToTerminalOnClick = defaults.bool(forKey: Key.returnToTerminal)
        watchCodexSessions = defaults.bool(forKey: Key.watchCodex)
        watchCoworkSessions = defaults.bool(forKey: Key.watchCowork)
        islandPlacement = IslandPlacement(rawValue: defaults.string(forKey: Key.islandPlacement) ?? "") ?? .automatic
        cloudEnabled = defaults.bool(forKey: Key.cloudEnabled)
        watchCodexCloud = defaults.bool(forKey: Key.watchCodexCloud)
        let channel = defaults.string(forKey: Key.cloudChannel).flatMap { $0.isEmpty ? nil : $0 } ?? CloudRelay.newChannel()
        defaults.set(channel, forKey: Key.cloudChannel)
        cloudChannel = channel
        visualizerAutoOpen = defaults.bool(forKey: Key.visualizerAutoOpen)
        visualizerFullScreen = defaults.bool(forKey: Key.visualizerFullScreen)
        visualizerAutoClose = defaults.bool(forKey: Key.visualizerAutoClose)
        visualizerPreset = VisualizerPreset(rawValue: defaults.string(forKey: Key.visualizerPreset) ?? "") ?? .magnetosphere
    }
}
