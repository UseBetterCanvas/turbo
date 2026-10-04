import TurboCore
import SwiftUI

/// A miniature Mac screen that loops through what the island does: cooking → done → gone.
struct IslandPreview: View {
    private enum Phase { case idle, cooking, done }
    @State private var phase: Phase = .idle

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .top) {
                DS.Palette.hex(0x221A45)
                Rectangle().fill(.black.opacity(0.25)).frame(height: 12)

                RoundedRectangle(cornerRadius: phase == .done ? 14 : 7, style: .continuous)
                    .fill(.black)
                    .frame(width: islandWidth(w), height: islandHeight)
                    .overlay(alignment: .top) { islandContent }
                    .shadow(color: .black.opacity(phase == .done ? 0.35 : 0), radius: 6, y: 3)
                    .offset(y: -2)
            }
        }
        .task {
            // Loop the story for as long as the preview is on screen.
            while !Task.isCancelled {
                for (next, hold) in [(Phase.cooking, 2.6), (.done, 2.2), (.idle, 0.9)] {
                    withAnimation(next == .done ? DS.Motion.bouncy : DS.Motion.standard) { phase = next }
                    try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
                    if Task.isCancelled { return }
                }
            }
        }
    }

    private func islandWidth(_ w: CGFloat) -> CGFloat {
        switch phase {
        case .idle: return w * 0.2
        case .cooking: return w * 0.42
        case .done: return w * 0.74
        }
    }

    private var islandHeight: CGFloat {
        phase == .done ? 50 : 16
    }

    @ViewBuilder
    private var islandContent: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .cooking:
            HStack {
                CookingFlame(tint: Agent.claude.tint, size: 8)
                Spacer()
                Text("1:24").font(.system(size: 7, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .frame(height: 16)
            .transition(.opacity)
        case .done:
            HStack(spacing: 7) {
                SuccessMark(tint: DS.Palette.ok, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code is done").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    Text("pancake-stack · 3m 12s").font(.system(size: 6.5)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 13)
            .transition(.blurFade)
        }
    }
}

/// The real visualizer engine, running small.
struct VisualizerPreview: View {
    var preset: VisualizerPreset = .magnetosphere
    var hue: Double = Agent.claude.hue
    @State private var engine = VisualizerEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            Canvas { context, size in
                engine.render(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .background(Color.black)
        .onAppear {
            engine.preset = preset
            engine.isCooking = true
            engine.palette = [hue]
        }
        .onChange(of: preset) { engine.transition(to: $0) }
        .task {
            // Fake tool calls so the preview dances.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.4...1.1) * 1_000_000_000))
                engine.kick(0.35, hue: hue)
            }
        }
    }
}
