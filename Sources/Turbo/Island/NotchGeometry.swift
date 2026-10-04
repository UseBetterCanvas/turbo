import AppKit

/// Where the hardware notch is (or where a fake one goes on screens without one), and whether
/// the island lives in it (`docked`) or floats just below it.
struct NotchGeometry: Equatable {
    var screenFrame: NSRect
    var hasNotch: Bool
    /// The notch's size; on notchless screens, a virtual one centered in the menu bar.
    var notchSize: CGSize
    /// false when another notch app owns the notch, so Turbo floats below it instead.
    var docked = true

    init(screen: NSScreen, docked: Bool = true) {
        screenFrame = screen.frame
        self.docked = docked
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            hasNotch = false
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 150, height: menuBar > 0 ? menuBar : 24)
        }
    }

    /// The built-in display if it has a notch, otherwise the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// Island sizes for each presentation, shared by the SwiftUI view and the panel's hit-testing.
enum IslandLayout {
    /// The panel is a fixed transparent canvas; the island draws inside it.
    static let canvasSize = CGSize(width: 680, height: 380)
    static let compactSideWidth: CGFloat = 76
    static let idleSideWidth: CGFloat = 34
    static let floatingIdleSize = CGSize(width: 86, height: 30)
    static let listFooterHeight: CGFloat = 40
    static let floatingCompactWidth: CGFloat = 248
    static let floatingCompactHeight: CGFloat = 38
    static let floatingGap: CGFloat = 6
    static let cardWidth: CGFloat = 404
    static let rowHeight: CGFloat = 46
    static let maxRows = 5

    /// Distance from the top of the screen to the top of the island.
    static func topInset(_ geometry: NotchGeometry) -> CGFloat {
        geometry.docked ? 0 : geometry.notchSize.height + floatingGap
    }

    /// Space at the top of the island hidden behind the notch.
    static func headroom(_ geometry: NotchGeometry) -> CGFloat {
        geometry.docked ? geometry.notchSize.height : 0
    }

    static func topRadius(for presentation: IslandPresentation) -> CGFloat {
        switch presentation {
        case .hidden, .idle, .compact: return 6
        case .spotlight, .list: return 14
        }
    }

    static func bottomRadius(for presentation: IslandPresentation) -> CGFloat {
        switch presentation {
        case .hidden, .idle, .compact: return 10
        case .spotlight, .list: return 26
        }
    }

    static func size(for presentation: IslandPresentation, geometry: NotchGeometry, rows: Int) -> CGSize {
        let notch = geometry.notchSize
        let flare = geometry.docked ? 2 * topRadius(for: presentation) : 0
        let cardWidth = max(Self.cardWidth, notch.width + 80) + flare
        switch presentation {
        case .hidden:
            return geometry.docked && geometry.hasNotch ? CGSize(width: notch.width + flare, height: notch.height) : CGSize(width: notch.width, height: 0)
        case .idle:
            return geometry.docked
                ? CGSize(width: notch.width + 2 * idleSideWidth + flare, height: notch.height)
                : floatingIdleSize
        case .compact:
            return geometry.docked
                ? CGSize(width: notch.width + 2 * compactSideWidth + flare, height: notch.height)
                : CGSize(width: floatingCompactWidth, height: floatingCompactHeight)
        case .spotlight:
            return CGSize(width: cardWidth, height: headroom(geometry) + 104)
        case .list:
            let count = CGFloat(min(max(rows, 1), maxRows))
            return CGSize(width: cardWidth, height: headroom(geometry) + count * rowHeight + 10 + listFooterHeight)
        }
    }

    /// The area that catches the mouse. When idle and docked, hovering the notch itself reveals
    /// recent sessions; when floating, an idle Turbo is invisible and leaves the notch alone.
    /// The area that catches the mouse: the island itself, in every shape. While the pop-up
    /// is open it handles its own events.
    static func hitRect(for presentation: IslandPresentation, geometry: NotchGeometry, rows: Int) -> NSRect {
        var size = size(for: presentation, geometry: geometry, rows: rows)
        if case .hidden = presentation { size = .zero }
        let frame = geometry.screenFrame
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - topInset(geometry) - size.height,
            width: size.width,
            height: size.height
        )
    }
}
