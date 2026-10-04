import AppKit
import SwiftUI

// Small, reusable motion pieces for the island and menus.

/// Blur + fade + slight shrink: how island content swaps between states.
struct BlurFade: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 10 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.94 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}

/// Rises into place a beat after its siblings, for a cascading entrance.
struct StaggeredAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .onAppear {
                withAnimation(DS.Motion.slow.delay(0.06 + Double(index) * 0.055)) { shown = true }
            }
    }
}

extension View {
    func staggered(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }

    /// Digits roll instead of snapping (macOS 14+).
    @ViewBuilder
    func numericTransition() -> some View {
        if #available(macOS 14, *) {
            self.contentTransition(.numericText())
        } else {
            self
        }
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.54))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.41, y: rect.minY + rect.height * 0.78))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.24))
        return p
    }
}

/// The "done" mark: a disc pops in, the check draws itself, and a ring of sparks bursts out.
struct SuccessMark: View {
    var tint: Color = DS.Palette.ok
    var size: CGFloat = 48
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false
    @State private var drawn: CGFloat = 0
    @State private var burst = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .stroke(tint.opacity(burst ? 0 : 0.7), lineWidth: burst ? 0.5 : 3)
                    .scaleEffect(burst ? 1.8 : 0.7)
                ForEach(0..<10, id: \.self) { i in
                    Capsule()
                        .fill(i.isMultiple(of: 2) ? tint : .white)
                        .frame(width: 2.5, height: burst ? 3 : 7)
                        .offset(y: burst ? -size * 0.78 : -size * 0.32)
                        .rotationEffect(.degrees(Double(i) * 36 + 18))
                        .opacity(burst ? 0 : 0.95)
                }
            }
            Circle()
                .fill(tint.opacity(0.2))
                .scaleEffect(popped ? 1 : 0.3)
            CheckShape()
                .trim(from: 0, to: drawn)
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.44, height: size * 0.44)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(DS.Motion.slow) { popped = true }
            withAnimation(.easeOut(duration: 0.32).delay(0.14)) { drawn = 1 }
            withAnimation(.easeOut(duration: 0.75).delay(0.12)) { burst = true }
        }
    }
}

/// A hand that waves for attention a few times, then holds still.
struct AttentionHand: View {
    var size: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wave = false

    var body: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(DS.Palette.gold)
            .rotationEffect(.degrees(wave ? 14 : -10), anchor: .bottom)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.16).repeatCount(7, autoreverses: true)) { wave = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(DS.Motion.slow) { wave = false }
                }
            }
    }
}

/// A sliver of light sweeping along the island's bottom edge while something cooks.
struct CookingShimmer: View {
    var tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            GeometryReader { geo in
                let period = 2.4
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let width = geo.size.width * 0.32
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: width, height: geo.size.height)
                    .offset(x: CGFloat(phase) * (geo.size.width + width) - width)
            }
        }
        .frame(height: 1.5)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// "Open Terminal ↗" — the app a click will take you back to.
struct HostAppChip: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            HStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 14, height: 14)
                Text("Open \(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))")
                    .font(.system(size: 10.5, weight: .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.12)))
        }
    }
}

/// Draws the countdown until a card dismisses itself; freezes (hidden) while hovered.
struct CountdownBar: View {
    let seconds: Double
    var tint: Color
    @State private var remaining: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(tint.opacity(0.55))
                .frame(width: geo.size.width * remaining, height: 2)
        }
        .frame(height: 2)
        .onAppear {
            withAnimation(.linear(duration: seconds)) { remaining = 0 }
        }
    }
}
