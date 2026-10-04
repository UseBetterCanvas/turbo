import AppKit
import TurboCore
import SwiftUI

final class VisualizerWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class VisualizerWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var window: VisualizerWindow?
    private var closeTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    var isOpen: Bool { window?.isVisible == true }

    func show() {
        closeTask?.cancel()
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if model.preferences.visualizerFullScreen && !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    func close() {
        closeTask?.cancel()
        window?.close()
    }

    /// After the finale, get out of the way and hand focus back to the agent's terminal.
    func turnFinished(_ session: AgentSession) {
        guard isOpen, model.preferences.visualizerAutoClose else { return }
        closeTask?.cancel()
        let delay = model.preferences.celebrateSeconds + 1.5
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.model.hasActive else { return }
            self.close()
            self.model.focusHost(of: session)
        }
    }

    private func makeWindow() -> VisualizerWindow {
        let screen = NotchGeometry.preferredScreen() ?? NSScreen.screens[0]
        let size = NSSize(width: screen.frame.width * 0.7, height: screen.frame.height * 0.7)
        let window = VisualizerWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Turbo"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: VisualizerView()
            .environmentObject(model)
            .environmentObject(model.preferences))
        window.center()
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        return window
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let prefs = model.preferences
        switch event.keyCode {
        case 53: // esc
            close()
        case 124, 49: // right arrow, space
            prefs.visualizerPreset = prefs.visualizerPreset.next
        case 123: // left arrow
            prefs.visualizerPreset = prefs.visualizerPreset.previous
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == "f" else { return false }
            window?.toggleFullScreen(nil)
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the window so the Canvas stops rendering; a fresh one is built next time.
        window?.contentView = nil
        window = nil
    }
}
