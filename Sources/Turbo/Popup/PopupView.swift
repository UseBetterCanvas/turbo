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
                ScrollView {
                    Group {
                        if model.popupPage == .settings { SettingsPage() } else { SessionsPage() }
                    }
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.top, DS.Space.m)
                    .padding(.bottom, DS.Space.xl)
                    .id(model.popupPage)
                    .transition(.opacity)
                }
                .background(DS.Palette.base)
            }
        }
        .animation(DS.Motion.base, value: model.popupPage)
    }

    /// Sits beside the notch: where you are on the left, actions on the right.
    private var header: some View {
        let height = max(geometry.docked ? geometry.notchSize.height : 0, 30) + 12
        let inSettings = model.popupPage == .settings
        return HStack(spacing: DS.Space.s) {
            if inSettings {
                HeaderButton(symbol: "chevron.left", help: "Back to sessions") { model.popupPage = .home }
                Text("Settings")
                    .font(DSFont.sans(14, .heavy))
                    .foregroundStyle(DS.Palette.textPrimary)
            } else {
                AppIconView(size: 20)
                Text("Turbo")
                    .font(DSFont.sans(14, .heavy))
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            Spacer()
            if model.popupPage != .welcome {
                HeaderButton(symbol: "sparkles", help: "Visualizer") { model.openVisualizer() }
                if !inSettings {
                    HeaderButton(symbol: "gearshape", help: "Settings") { model.popupPage = .settings }
                }
            }
            HeaderButton(symbol: "xmark", help: "Close (esc)") { model.closePopup() }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, geometry.docked ? 4 : 8)
        .frame(height: height)
        .background(geometry.docked ? Color.black : DS.Palette.rail)
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
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? DS.Palette.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(hovering ? nil : DS.Motion.out, value: hovering)
    }
}
