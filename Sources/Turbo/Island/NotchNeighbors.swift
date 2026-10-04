import AppKit

/// Spots other apps that draw over the notch (HeyClicky, NotchNook, boring.notch, Alcove…) so Turbo can
/// step aside instead of fighting them for the same pixels and hover events.
@MainActor
final class NotchNeighbors: ObservableObject {
    /// Names of the notch apps running right now.
    @Published private(set) var running: [String] = []

    static let knownBundleIDs: Set<String> = [
        "lo.cafe.NotchNook",
        "theboringteam.boringnotch",
        "com.henrikruscon.Alcove",
        "com.lakr233.NotchDrop",
        "com.tweety.MediaMate",
        "com.ebullioscopic.Atoll",
        "app.droppy.Droppy",
    ]

    /// Catches apps we don't know by id. Lowercased substrings of the app name.
    static let nameHints = ["notch", "clicky", "alcove", "dynamic island", "dynamiclake", "dynamic lake", "mediamate", "atoll", "droppy"]

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    func refresh() {
        let names = NSWorkspace.shared.runningApplications
            .filter(Self.drawsOverNotch)
            .compactMap { $0.localizedName ?? $0.bundleIdentifier }
        let unique = Array(Set(names)).sorted()
        if unique != running { running = unique }
    }

    static func drawsOverNotch(_ app: NSRunningApplication) -> Bool {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        if let id = app.bundleIdentifier, knownBundleIDs.contains(id) { return true }
        let name = (app.localizedName ?? "").lowercased()
        return nameHints.contains { name.contains($0) }
    }
}
