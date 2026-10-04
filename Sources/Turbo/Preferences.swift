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

/// Where cloud sessions open when you click Open.
enum OpenTarget: String, CaseIterable, Identifiable {
    /// The Claude app (or the ChatGPT app for Codex), falling back to the browser.
    case app
    case browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "The app"
        case .browser: return "Browser"
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
    @Published var openSessionsIn: OpenTarget { didSet { defaults.set(openSessionsIn.rawValue, forKey: Key.openSessionsIn) } }
    /// The private relay channel cloud sessions post to. Generated once; resettable.
    @Published var cloudChannel: String { didSet { defaults.set(cloudChannel, forKey: Key.cloudChannel) } }
    /// Cloud sessions send the first few words of each prompt, so they get real names.
    @Published var cloudShareTitles: Bool { didSet { defaults.set(cloudShareTitles, forKey: Key.cloudShareTitles) } }
    /// The setup script you last copied, so Turbo can tell you when there's a newer one.
    @Published var copiedCloudScript: String { didSet { defaults.set(copiedCloudScript, forKey: Key.copiedCloudScript) } }
    /// Install new versions on their own when nothing's cooking.
    @Published var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: Key.autoUpdate) } }
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
        static let openSessionsIn = "openSessionsIn"
        static let cloudChannel = "cloudChannel"
        static let visualizerAutoOpen = "visualizerAutoOpen"
        static let visualizerFullScreen = "visualizerFullScreen"
        static let visualizerAutoClose = "visualizerAutoClose"
        static let visualizerPreset = "visualizerPreset"
        static let onboarded = "hasOnboarded"
        static let cloudShareTitles = "cloudShareTitles"
        static let copiedCloudScript = "copiedCloudScript"
        static let autoUpdate = "autoUpdate"
    }

    /// Visualizer used to be a mode that auto-opened by default. Keep that behavior for anyone who
    /// picked it, unless they had explicitly turned auto-open off.
    private func migrateVisualizerMode() {
        let migratedKey = "migratedVisualizerMode"
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        let saved = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let choseVisualizer = saved[Key.mode] as? String == CookMode.visualizer.rawValue
        let explicitAutoOpen = saved[Key.visualizerAutoOpen] as? Bool
        if choseVisualizer && explicitAutoOpen != false {
            visualizerAutoOpen = true
        }
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
            Key.openSessionsIn: OpenTarget.app.rawValue,
            Key.visualizerAutoOpen: false,
            Key.visualizerFullScreen: true,
            Key.visualizerAutoClose: true,
            Key.visualizerPreset: VisualizerPreset.magnetosphere.rawValue,
            Key.cloudShareTitles: false,
            Key.autoUpdate: true,
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
        openSessionsIn = OpenTarget(rawValue: defaults.string(forKey: Key.openSessionsIn) ?? "") ?? .app
        let channel = defaults.string(forKey: Key.cloudChannel).flatMap { $0.isEmpty ? nil : $0 } ?? CloudRelay.newChannel()
        defaults.set(channel, forKey: Key.cloudChannel)
        cloudChannel = channel
        visualizerAutoOpen = defaults.bool(forKey: Key.visualizerAutoOpen)
        visualizerFullScreen = defaults.bool(forKey: Key.visualizerFullScreen)
        visualizerAutoClose = defaults.bool(forKey: Key.visualizerAutoClose)
        visualizerPreset = VisualizerPreset(rawValue: defaults.string(forKey: Key.visualizerPreset) ?? "") ?? .magnetosphere
        cloudShareTitles = defaults.bool(forKey: Key.cloudShareTitles)
        // Set up cloud before Turbo tracked the script? That one predates Stop and step details.
        copiedCloudScript = defaults.string(forKey: Key.copiedCloudScript) ?? (defaults.bool(forKey: Key.cloudEnabled) ? "legacy" : "")
        autoUpdate = defaults.bool(forKey: Key.autoUpdate)
        migrateVisualizerMode()
    }
}
