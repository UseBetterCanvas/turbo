import AppKit
import Combine
import SwiftUI

@main
struct TurboApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Turbo has no regular windows: it's always the island, the bigger island, or the
        // pop-up from the notch. SwiftUI still wants a scene.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, no Dock icon (also set via LSUIElement when bundled).
        NSApp.setActivationPolicy(.accessory)
        DSFont.register()
        AppModel.shared.start()
        statusItem = StatusItemController(model: AppModel.shared)
    }
}

/// The paw in the menu bar. One click opens the session board; it also shows how many
/// sessions are cooking, and turns into a raised hand when one needs you.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private var cancellable: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        refresh()
        cancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        guard let button = item.button else { return }
        let waiting = model.needsYouCount
        let cooking = model.board.cooking.count
        let symbol = waiting > 0 ? "hand.raised.fill" : (cooking > 0 ? "pawprint.fill" : "pawprint")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Turbo")
        image?.isTemplate = true
        button.image = image
        let count = waiting > 0 ? waiting : cooking
        button.title = count > 0 ? " \(count)" : ""
        var tip: [String] = [waiting > 0 ? "\(waiting) need you" : cooking > 0 ? "\(cooking) cooking" : "Turbo"]
        if let usage = model.usage {
            var line = "Session \(usage.fiveHour)%"
            if let week = usage.week { line += ", week \(week)%" }
            tip.append(line)
        }
        if model.isQuiet { tip.append("Quiet") }
        if model.hotKeyAvailable { tip.append("⌃⌥Space") }
        button.toolTip = tip.joined(separator: " · ")
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Turbo", action: #selector(openBoard), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Open Visualizer", action: #selector(openVisualizer), keyEquivalent: "").target = self
            menu.addItem(.separator())
            if model.isQuiet {
                menu.addItem(withTitle: "Turn Alerts Back On", action: #selector(resumeAlerts), keyEquivalent: "").target = self
            } else {
                menu.addItem(withTitle: "Quiet for 1 Hour", action: #selector(quietHour), keyEquivalent: "").target = self
                menu.addItem(withTitle: "Quiet Until Tomorrow", action: #selector(quietTomorrow), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Welcome Tour", action: #selector(tour), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Quit Turbo", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            model.togglePopup()
        }
    }

    @objc private func openBoard() { model.openPopup(.home) }
    @objc private func openVisualizer() { model.openVisualizer() }
    @objc private func quietHour() { model.setQuiet(for: 3600) }
    @objc private func resumeAlerts() { model.setQuiet(for: nil) }
    @objc private func quietTomorrow() {
        let morning = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 8), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(12 * 3600)
        model.setQuiet(for: morning.timeIntervalSinceNow)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func tour() { model.showOnboarding() }
}
