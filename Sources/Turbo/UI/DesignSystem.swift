import AppKit
import CoreText
import SwiftUI
import TurboCore

/// Turbo's design system, ported from BetterCampus (DESIGN.md v2.2, `apps/wxt/src/assets/tailwind.css`).
///
/// - Dark first. Depth comes from stepped fills (deep-4 → deep-1), not shadows.
/// - Blurple is the brand and the one primary action per view. It's never a status color.
/// - Flat color only: no gradients.
/// - Pressables carry the BetterCampus "edge": a hard 3px shadow that lifts on hover and
///   presses down on click. Hover/press apply instantly and ease out over 150ms. No springs.
/// - Figtree for UI, Archivo for display, JetBrains Mono for data.
enum DS {
    // MARK: Color

    enum Palette {
        // Blurple
        static let brand = hex(0x4F49F3)                                    // bp-600: every solid button
        static let brandHover = dynamic(light: 0x342DF2, dark: 0x625DF5)
        static let brandText = dynamic(light: 0x342DF2, dark: 0xC7C6F9)     // links, active nav
        static let ring = hex(0x827EF6)                                     // focus ring
        static let brandEdge = dynamic(light: 0x35319F, dark: 0x2E2A8D)     // brand mixed with black (30% / 42%)

        // Signals (text value flips per theme)
        static let ok = dynamic(light: 0x257474, dark: 0x44C3C3)
        static let gold = dynamic(light: 0x855600, dark: 0xFFC65C)
        static let bad = dynamic(light: 0xCF3917, dark: 0xFF623E)
        static let info = dynamic(light: 0x3D5A70, dark: 0x77C4FF)
        static let destructiveFace = hex(0xCF3917)

        // Surfaces: lightness ascends toward the viewer
        static let rail = dynamic(light: 0xFAFAFA, dark: 0x1A1A1A)      // deep-4: app frame, sidebars
        static let base = dynamic(light: 0xFFFFFF, dark: 0x212121)      // deep-3: base surface
        static let card = dynamic(light: 0xF7F7F7, dark: 0x2A2A2A)      // deep-2: cards, panels
        static let overlay = dynamic(light: 0xFFFFFF, dark: 0x333333)   // deep-1: popovers, row hover
        static let sunken = dynamic(light: 0xF2F1F4, dark: 0x212121)    // input wells, tracks
        static let hover = dynamic(light: 0xF2F1F4, dark: 0x333333)
        static let border = dynamic(light: 0xD7D5DD, dark: 0x3D3D3D)
        static let divider = dynamic(light: 0xD7D5DD, dark: 0x333333)

        // Text
        static let textPrimary = dynamic(light: 0x212121, dark: 0xF7F7F8)
        static let textSecondary = dynamic(light: 0x6C6685, dark: 0xBCB8C7)   // muted-fg
        static let textTertiary = hex(0x9797A5)

        // Aliases the rest of the app uses
        static let accent = brand
        static let success = ok
        static let warning = gold
        static let danger = bad
        static let windowBackground = base
        static let surface = card
        static let surfaceRaised = overlay
        static let separator = border

        static func hex(_ value: UInt32) -> Color {
            Color(nsColor: nsHex(value))
        }

        static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? nsHex(dark) : nsHex(light)
            })
        }

        static func nsHex(_ value: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    // MARK: Type

    enum Typography {
        static let display = DSFont.display(28)
        static let title = DSFont.sans(22, .heavy).leading(.tight)
        static let h3 = DSFont.sans(17, .bold)
        static let headline = DSFont.sans(14.5, .bold)
        static let body = DSFont.sans(13.5)
        static let bodyStrong = DSFont.sans(13.5, .semibold)
        static let caption = DSFont.sans(12, .medium)
        static let captionStrong = DSFont.sans(12, .semibold)
        static let overline = DSFont.sans(10.5, .heavy)
        static let eyebrow = overline
        static let mono = DSFont.mono(12)
    }

    // MARK: Space, shape, motion

    /// 4pt grid: --s-1 … --s-8.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let section: CGFloat = 48
    }

    enum Radius {
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 14
        static let group: CGFloat = 16
        static let xl: CGFloat = 20
        static let dialog: CGFloat = 24
    }

    /// One curve everywhere: cubic-bezier(0.2, 0.8, 0.3, 1). Nothing longer than 300ms.
    enum Motion {
        static let fast = Animation.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.12)
        static let base = Animation.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.18)
        static let slow = Animation.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.26)
        static let out = Animation.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.15)
        /// Dialogs are the one exception to the single curve.
        static let dialogOpen = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.3)
        static let dialogClose = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.2)

        // Aliases
        static let quick = fast
        static let standard = base
        static let bouncy = dialogOpen
    }
}

// MARK: - Fonts

/// Registers the bundled Figtree, Archivo and JetBrains Mono, falling back to system fonts
/// when they're missing (e.g. `swift run` without a bundle).
enum DSFont {
    private(set) static var available = false

    static func register() {
        let fontsDir = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
        guard let fontsDir, let files = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        available = NSFont(name: "Figtree", size: 12) != nil
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        available ? Font.custom("Figtree", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func display(_ size: CGFloat) -> Font {
        NSFont(name: "Archivo", size: size) != nil
            ? Font.custom("Archivo", size: size).weight(.black)
            : .system(size: size, weight: .black, design: .rounded)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        NSFont(name: "JetBrains Mono", size: size) != nil
            ? Font.custom("JetBrains Mono", size: size).weight(weight)
            : .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Buttons (with the BetterCampus edge)

enum ButtonVariant {
    case primary, secondary, outline, ghost, destructive
}

enum ButtonSize {
    case sm, md

    var height: CGFloat { self == .sm ? 32 : 40 }
    var radius: CGFloat { self == .sm ? 10 : 13 }
    var hPadding: CGFloat { self == .sm ? 12 : 16 }
    var font: Font { self == .sm ? DSFont.sans(13, .semibold) : DSFont.sans(14, .semibold) }
}

struct BCButtonStyle: ButtonStyle {
    var variant: ButtonVariant = .primary
    var size: ButtonSize = .md
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        BCButtonBody(configuration: configuration, variant: variant, size: size, fullWidth: fullWidth)
    }
}

private struct BCButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: ButtonVariant
    let size: ButtonSize
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        let lifted = hovering && isEnabled && !pressed
        let hasEdge = variant != .ghost && isEnabled
        let edge: CGFloat = !hasEdge ? 0 : pressed ? 1 : lifted ? 4 : 3
        let offset: CGFloat = variant == .ghost ? (pressed ? 1 : 0) : (pressed ? 2 : lifted ? -1 : 0)
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)

        configuration.label
            .font(size.font)
            .foregroundStyle(foreground)
            .padding(.horizontal, size.hPadding)
            .frame(height: size.height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                ZStack {
                    if hasEdge { shape.fill(edgeColor).offset(y: edge) }
                    shape.fill(variant == .ghost && hovering ? DS.Palette.brand.opacity(0.15) : face)
                    if variant == .secondary || variant == .outline { shape.strokeBorder(DS.Palette.border, lineWidth: 1) }
                }
            )
            .offset(y: offset)
            .padding(.bottom, hasEdge ? 3 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // Instant in, eased out.
            .animation(pressed || lifted ? nil : DS.Motion.out, value: pressed)
            .animation(pressed || lifted ? nil : DS.Motion.out, value: lifted)
    }

    private var face: Color {
        switch variant {
        case .primary: return hovering ? DS.Palette.brandHover : DS.Palette.brand
        case .secondary: return DS.Palette.overlay
        case .outline: return DS.Palette.base
        case .ghost: return .clear
        case .destructive: return DS.Palette.destructiveFace
        }
    }

    private var edgeColor: Color {
        switch variant {
        case .primary: return DS.Palette.brandEdge
        case .destructive: return DS.Palette.nsHex(0x7F230E).asColor
        default: return Color.black.opacity(0.35)
        }
    }

    private var foreground: Color {
        switch variant {
        case .primary, .destructive: return .white
        case .ghost: return hovering ? DS.Palette.textPrimary : DS.Palette.textSecondary
        default: return DS.Palette.textPrimary
        }
    }
}

private extension NSColor {
    var asColor: Color { Color(nsColor: self) }
}

/// Names the rest of the app already uses.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    func makeBody(configuration: Configuration) -> some View {
        BCButtonStyle(variant: .primary, size: .sm, fullWidth: fullWidth).makeBody(configuration: configuration)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = false
    func makeBody(configuration: Configuration) -> some View {
        BCButtonStyle(variant: .secondary, size: .sm, fullWidth: fullWidth).makeBody(configuration: configuration)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BCButtonStyle(variant: .ghost, size: .sm).makeBody(configuration: configuration)
    }
}

// MARK: - Switch and segmented control

/// The BetterCampus switch: Blurple track when on, sunken when off, white thumb with a hard shadow.
struct BCSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Capsule()
            .fill(on ? DS.Palette.brand : DS.Palette.sunken)
            .overlay(Capsule().strokeBorder(on ? Color.clear : DS.Palette.border, lineWidth: 1))
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.16), radius: 0, y: 2)
                    .padding(2.5)
            }
            .frame(width: 34, height: 20)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .animation(DS.Motion.fast, value: on)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(on ? "On" : "Off")
    }
}

struct SegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var symbol: String?
    var id: Value { value }
}

/// A sunken track with one sliding face, like BetterCampus' SegmentedToggle.
struct BCSegmented<Value: Hashable>: View {
    let options: [SegmentOption<Value>]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(DS.Motion.fast) { selection = option.value }
                } label: {
                    HStack(spacing: 6) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                        Text(option.label)
                    }
                    .font(DSFont.sans(12.5, .bold))
                    .foregroundStyle(selected ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.black.opacity(0.35))
                                .offset(y: 3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(DS.Palette.card)
                                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.Palette.border, lineWidth: 1))
                                )
                                .matchedGeometryEffect(id: "face", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .padding(.bottom, 3)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(DS.Palette.sunken)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.border, lineWidth: 1))
        )
    }
}

// MARK: - Surfaces

/// A card: deep-2 fill, radius 14, the lightest shadow, no border.
struct Card<Content: View>: View {
    var padding: CGFloat = DS.Space.l
    var highlighted = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .fill(DS.Palette.card)
                    .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .strokeBorder(highlighted ? DS.Palette.brand : .clear, lineWidth: 2)
            )
    }
}

/// The overline: 11px, heavy, +0.13em, uppercase, muted.
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DS.Typography.overline)
            .tracking(1.4)
            .foregroundStyle(DS.Palette.textSecondary)
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title)
                .font(DS.Typography.title)
                .tracking(-0.4)
                .foregroundStyle(DS.Palette.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A neutral rounded tile (28% radius) holding a symbol in an identity color.
struct IconTile: View {
    let symbol: String
    var tint: Color = DS.Palette.brandText
    var size: CGFloat = 32
    var filled = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(filled ? tint : DS.Palette.overlay)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(filled ? .white : tint)
            )
    }
}

// MARK: - Status

enum StatusTone {
    case good, attention, neutral, bad, info

    var color: Color {
        switch self {
        case .good: return DS.Palette.ok
        case .attention: return DS.Palette.gold
        case .neutral: return DS.Palette.textSecondary
        case .bad: return DS.Palette.bad
        case .info: return DS.Palette.info
        }
    }
}

/// A BetterCampus badge: uppercase pill, signal text on a 12% wash with a 34% border.
struct StatusPill: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        Text(text.uppercased())
            .font(DSFont.sans(10.5, .heavy))
            .tracking(0.5)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tone == .neutral ? Color.clear : tone.color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tone == .neutral ? DS.Palette.border : tone.color.opacity(0.34), lineWidth: 1))
            .fixedSize()
    }
}

/// A notice, styled like a BetterCampus toast: overlay fill and a leading signal dot.
struct Callout: View {
    let symbol: String
    let text: String
    var tone: StatusTone = .info

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Circle().fill(tone.color).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(text)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Palette.textPrimary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(DS.Palette.overlay))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.border, lineWidth: 1))
    }
}

/// Dashed, centered, one action at most.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(DS.Palette.textTertiary)
                .padding(.bottom, DS.Space.xs)
            Text(title)
                .font(DSFont.sans(19, .heavy))
                .tracking(-0.3)
            Text(message)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
            action().padding(.top, DS.Space.s)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(DS.Palette.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}

// MARK: - Settings rows

/// Label and explanation on the left, the control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DS.Typography.bodyStrong).foregroundStyle(DS.Palette.textPrimary)
                if let detail {
                    Text(detail)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.m)
            control()
        }
        .padding(.vertical, 14)
    }
}

struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).toggleStyle(BCSwitchStyle()).labelsHidden()
        }
    }
}

/// A settings block: muted label, then a radius-16 surface with hairline-divided rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let title {
                Text(title)
                    .font(DSFont.sans(13, .medium))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.leading, DS.Space.xs)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, DS.Space.l)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous)
                    .fill(DS.Palette.card)
                    .shadow(color: .black.opacity(0.22), radius: 0.5, y: 1)
            )
        }
    }
}

/// A hairline between rows in a SettingsGroup.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(DS.Palette.divider).frame(height: 1)
    }
}

/// A selection tile: the only thing that magnifies on hover.
struct ChoiceCard<Preview: View>: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var preview: () -> Preview
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                preview()
                    .frame(height: 104)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(DS.Typography.headline).foregroundStyle(DS.Palette.textPrimary)
                        Text(detail)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    ZStack {
                        Circle().strokeBorder(selected ? DS.Palette.brand : DS.Palette.border, lineWidth: 1.5)
                        if selected {
                            Circle().fill(DS.Palette.brand).padding(0.5)
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 18, height: 18)
                }
            }
            .padding(DS.Space.m)
            .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.overlay))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .strokeBorder(selected ? DS.Palette.brand : .clear, lineWidth: 2)
            )
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.slow, value: hovering)
        .animation(DS.Motion.fast, value: selected)
    }
}

/// The app icon, falling back to a tile when running unbundled (`swift run`).
struct AppIconView: View {
    var size: CGFloat = 64

    var body: some View {
        if Bundle.main.bundlePath.hasSuffix(".app"), let icon = NSApp.applicationIconImage {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            IconTile(symbol: "graduationcap.fill", tint: DS.Palette.brand, size: size * 0.82, filled: true)
                .frame(width: size, height: size)
        }
    }
}

extension Agent {
    /// Plain-language description used in setup and settings.
    var setupBlurb: String {
        switch self {
        case .claude: return "Claude Code in your terminal or the desktop app. One click adds a tiny notifier that stays silent unless Turbo is running."
        case .codex: return "Nothing to set up. Turbo reads Codex's session logs to see when it starts and finishes."
        case .cowork: return "Nothing to set up. Turbo reads Cowork's session logs from the Claude desktop app."
        case .cloud: return "Claude Code sessions on claude.ai/code. Add one setup script to your cloud environment and every session checks in."
        }
    }
}
