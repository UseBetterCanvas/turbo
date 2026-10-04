import AppKit
import SwiftUI

/// A regular window with traffic lights. Keys it doesn't use go to the board's triage keys.
final class TurboWindow: NSWindow {
    var onKey: ((String, UInt16) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, onKey?(event.charactersIgnoringModifiers ?? "", event.keyCode) == true { return }
        super.keyDown(with: event)
    }
}

/// The third shape: Turbo's two-pane view in its own window, to keep beside your work.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: TurboWindow?

    init(model: AppModel) {
        self.model = model
    }

    var isOpen: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.windowOpen = true
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> TurboWindow {
        let window = TurboWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Turbo"
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        window.minSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        let root = MainView(host: .window)
            .environmentObject(model)
            .environmentObject(model.preferences)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
        window.contentView = NSHostingView(rootView: root)
        window.onKey = { [weak model] characters, keyCode in
            model?.handleBoardKey(characters, keyCode: keyCode) ?? false
        }
        window.center()
        window.setFrameAutosaveName("TurboMainWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.windowOpen = false
    }
}
