import AppKit
import Combine
import SwiftUI

/// A borderless, non-activating panel parked over the notch. It's a fixed transparent canvas;
/// mouse events pass through except over the island itself.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Allow sitting over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Screen geometry for the view, updated when displays change.
@MainActor
final class IslandState: ObservableObject {
    @Published var geometry: NotchGeometry

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

@MainActor
final class IslandPanelController {
    private let model: AppModel
    private let panel = IslandPanel()
    private let state: IslandState
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        let screen = NotchGeometry.preferredScreen() ?? NSScreen.screens[0]
        state = IslandState(geometry: NotchGeometry(screen: screen, docked: model.isDocked))

        let root = IslandView()
            .environmentObject(model)
            .environmentObject(model.preferences)
            .environmentObject(state)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: IslandLayout.canvasSize)
        panel.contentView = hosting
        layout()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGeometry() }
            .store(in: &cancellables)

        // Step out of (or back into) the notch as other notch apps come and go.
        model.neighbors.$running.map { _ in () }
            .merge(with: model.preferences.$islandPlacement.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGeometry() }
            .store(in: &cancellables)

        // When the island grows or shrinks under a still cursor, re-evaluate hit-testing.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateHover() }
            .store(in: &cancellables)

        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.updateHover() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    private func refreshGeometry() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen, docked: model.isDocked)
        guard geometry != state.geometry else { return }
        state.geometry = geometry
        layout()
    }

    private func layout() {
        let frame = state.geometry.screenFrame
        let size = IslandLayout.canvasSize
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    private func updateHover() {
        let rect = IslandLayout.hitRect(for: model.presentation, geometry: state.geometry, rows: model.sessions.count)
        let location = NSEvent.mouseLocation
        let inside = rect.height > 0 && rect.insetBy(dx: -2, dy: -2).contains(location)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        // Over the idle island's gear (its right side), stay put so the gear can be clicked.
        var overGear = false
        if inside, model.presentation == .idle {
            let geometry = state.geometry
            let gearStart = geometry.docked && geometry.hasNotch
                ? geometry.screenFrame.midX + geometry.notchSize.width / 2
                : rect.maxX - 26
            overGear = location.x >= gearStart
        }
        model.setPointerInside(inside, expand: !overGear)
    }
}
