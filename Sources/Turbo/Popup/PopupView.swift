import SwiftUI
import TurboCore

/// The pop-up: grows out of the notch (or out of the floating island when another app owns the
/// notch) and holds everything that isn't an island.
struct PopupRoot: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var state: PopupState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let geometry = state.geometry
        let open = model.popupOpen
        let closed = closedSize(geometry)
        let size = open ? PopupController.size : closed

        VStack(spacing: 0) {
            Color.clear.frame(height: IslandLayout.topInset(geometry))

            ZStack(alignment: .top) {
                PopupBackground(docked: geometry.docked, notchHeight: geometry.notchSize.height, open: open)

                PopupContent(geometry: geometry)
                    .frame(width: PopupController.size.width, height: PopupController.size.height)
                    .opacity(open ? 1 : 0)
                    .blur(radius: open || reduceMotion ? 0 : 8)
                    .scaleEffect(open || reduceMotion ? 1 : 0.96, anchor: .top)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(PopupClip(docked: geometry.docked, open: open))
            .shadow(color: .black.opacity(open ? 0.85 : 0), radius: 32, y: 18)

            Spacer(minLength: 0)
        }
        .frame(width: PopupController.canvas.width, height: PopupController.canvas.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private func closedSize(_ geometry: NotchGeometry) -> CGSize {
        geometry.docked
            ? CGSize(width: geometry.notchSize.width, height: geometry.notchSize.height)
            : CGSize(width: IslandLayout.floatingCompactWidth, height: IslandLayout.floatingCompactHeight)
    }
}

private struct PopupClip: Shape {
    var docked: Bool
    var open: Bool

    func path(in rect: CGRect) -> Path {
        if docked {
            return NotchShape(topRadius: open ? 16 : 6, bottomRadius: open ? DS.Radius.dialog : 10).path(in: rect)
        }
        return RoundedRectangle(cornerRadius: open ? DS.Radius.dialog : rect.height / 2, style: .continuous).path(in: rect)
    }
}

/// Black where it meets the hardware notch, then BetterCampus' deep surfaces. The short fade
/// under the notch is the one blend in the app: it's there so the panel reads as part of the
/// notch rather than a window stuck under it.
private struct PopupBackground: View {
    let docked: Bool
    let notchHeight: CGFloat
    let open: Bool

    var body: some View {
        ZStack(alignment: .top) {
            DS.Palette.base
            if docked {
                VStack(spacing: 0) {
                    Color.black.frame(height: notchHeight)
                    LinearGradient(colors: [.black, Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 22)
                }
            }
        }
        .overlay {
            if !docked {
                RoundedRectangle(cornerRadius: open ? DS.Radius.dialog : 19, style: .continuous)
                    .strokeBorder(DS.Palette.border, lineWidth: 1)
            }
        }
    }
}

private struct PopupContent: View {
    @EnvironmentObject private var model: AppModel
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.popupPage == .welcome {
                WelcomeFlow()
                    .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    PopupSidebar()
                    Rectangle().fill(DS.Palette.divider).frame(width: 1)
                    ScrollView {
                        page
                            .padding(.horizontal, DS.Space.xl)
                            .padding(.vertical, DS.Space.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(model.popupPage)
                            .transition(.opacity)
                    }
                    .background(DS.Palette.base)
                }
            }
        }
        .animation(DS.Motion.base, value: model.popupPage)
    }

    /// Lives beside the notch: brand on the left, actions on the right.
    private var header: some View {
        let height = max(geometry.docked ? geometry.notchSize.height : 0, 30) + 10
        return HStack(spacing: DS.Space.s) {
            AppIconView(size: 20)
            Text("Turbo")
                .font(DSFont.sans(14, .heavy))
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer()
            if model.board.activeCount > 0 {
                StatusPill(text: "\(model.board.activeCount) cooking", tone: .neutral)
            }
            HeaderButton(symbol: "sparkles", help: "Open the visualizer") { model.openVisualizer() }
            HeaderButton(symbol: "xmark", help: "Close (esc)") { model.closePopup() }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, geometry.docked ? 4 : 8)
        .frame(height: height)
        .background(geometry.docked ? Color.black : DS.Palette.rail)
    }

    @ViewBuilder
    private var page: some View {
        switch model.popupPage {
        case .welcome, .home: SessionsPage()
        case .agents: AgentsPage()
        case .island: IslandPage()
        case .visualizer: VisualizerPage()
        case .about: AboutPage()
        }
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? DS.Palette.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(hovering ? nil : DS.Motion.out, value: hovering)
    }
}

/// The BetterCampus settings rail: deep-4, filled rounded active row in brand-text.
private struct PopupSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(PopupPage.navigation) { page in
                SidebarItem(page: page, selected: model.popupPage == page, badge: badge(for: page)) {
                    model.popupPage = page
                }
            }
            Spacer()
            sessionSummary
        }
        .padding(DS.Space.s)
        .padding(.top, DS.Space.xs)
        .frame(width: 168)
        .background(DS.Palette.rail)
    }

    private func badge(for page: PopupPage) -> Int? {
        page == .home && model.needsYouCount > 0 ? model.needsYouCount : nil
    }

    private var sessionSummary: some View {
        let board = model.board
        return VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Right now")
            summaryLine(color: DS.Palette.gold, count: board.needsYou.count, label: "need you")
            summaryLine(color: DS.Palette.brandText, count: board.cooking.count, label: "cooking")
            summaryLine(color: DS.Palette.ok, count: board.done.count, label: "done")
        }
        .padding(DS.Space.s)
    }

    private func summaryLine(color: Color, count: Int, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(count > 0 ? color : DS.Palette.border).frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(DSFont.sans(12, .medium).monospacedDigit())
                .foregroundStyle(count > 0 ? DS.Palette.textPrimary : DS.Palette.textTertiary)
        }
    }
}

private struct SidebarItem: View {
    let page: PopupPage
    let selected: Bool
    var badge: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text(page.title).font(DSFont.sans(13, .medium))
                Spacer()
                if let badge {
                    Text("\(badge)")
                        .font(DSFont.sans(10.5, .heavy).monospacedDigit())
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(DS.Palette.gold))
                }
            }
            .foregroundStyle(selected ? DS.Palette.brandText : DS.Palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(selected ? DS.Palette.brandText.opacity(0.18) : hovering ? DS.Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(hovering ? nil : DS.Motion.out, value: hovering)
    }
}
