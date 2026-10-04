import AppKit
import Combine
import SwiftUI

enum PopupPage: String, CaseIterable, Identifiable {
    case welcome, home, agents, island, visualizer, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .home: return "Sessions"
        case .agents: return "Agents"
        case .island: return "Island"
        case .visualizer: return "Visualizer"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "hand.wave"
        case .home: return "square.stack.3d.up"
        case .agents: return "link"
        case .island: return "capsule"
        case .visualizer: return "sparkles"
        case .about: return "info.circle"
        }
    }

    static let navigation: [PopupPage] = [.home, .agents, .island, .visualizer, .about]
}

/// A borderless panel that can take keyboard focus without activating Turbo, so your
/// terminal stays the active app underneath.
final class PopupPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// Geometry for the pop-up view.
@MainActor
final class PopupState: ObservableObject {
    @Published var geometry: NotchGeometry

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

/// The third of Turbo's three shapes: the pop-up that grows out of the notch.
@MainActor
final class PopupController {
    static let size = CGSize(width: 800, height: 560)
    /// Room around the pop-up for its shadow.
    static let canvas = CGSize(width: 880, height: 640)

    private let model: AppModel
    private let panel = PopupPanel()
    private let state: PopupState
    private var clickMonitor: Any?
    private var closeWork: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
        let screen = NotchGeometry.preferredScreen() ?? NSScreen.screens[0]
        state = PopupState(geometry: NotchGeometry(screen: screen, docked: model.isDocked))
        let root = PopupRoot()
            .environmentObject(model)
            .environmentObject(model.preferences)
            .environmentObject(state)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.canvas)
        panel.contentView = hosting
        panel.onEscape = { [weak self] in self?.close() }
    }

    func open() {
        closeWork?.cancel()
        if let screen = NotchGeometry.preferredScreen() {
            state.geometry = NotchGeometry(screen: screen, docked: model.isDocked)
        }
        let frame = state.geometry.screenFrame
        panel.setFrame(NSRect(x: frame.midX - Self.canvas.width / 2, y: frame.maxY - Self.canvas.height, width: Self.canvas.width, height: Self.canvas.height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        withAnimation(DS.Motion.dialogOpen) { model.popupOpen = true }

        if clickMonitor == nil {
            // Clicking anywhere outside closes it, like a popover.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
    }

    func close() {
        guard model.popupOpen else { return }
        withAnimation(DS.Motion.dialogClose) { model.popupOpen = false }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.popupOpen else { return }
            self.panel.orderOut(nil)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }
}
