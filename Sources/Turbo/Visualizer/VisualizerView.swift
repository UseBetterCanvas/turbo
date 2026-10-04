import AppKit
import TurboCore
import SwiftUI

struct VisualizerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    @State private var engine = VisualizerEngine()
    @State private var chromeVisible = true
    @State private var lastMouseMove = Date()
    @State private var toast: VisualizerPreset?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    engine.render(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 10) {
                        KeyHint(keys: "← →", label: "look")
                        KeyHint(keys: "F", label: "full screen")
                        KeyHint(keys: "esc", label: "close")
                    }
                    .opacity(chromeVisible ? 1 : 0)
                }
                Spacer()
                HStack(alignment: .bottom) {
                    NowCookingCard(sessions: model.sessions)
                        .opacity(chromeVisible || model.hasActive ? 1 : 0.35)
                    Spacer()
                    Text(prefs.visualizerPreset.title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.35))
                        .opacity(chromeVisible ? 1 : 0)
                }
            }
            .padding(28)

            if let toast {
                Text(toast.title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.black.opacity(0.35)))
                    .transition(.blurFade)
                    .id(toast)
            }

            if let spotlight = model.spotlight, spotlight.kind == .finished, !spotlight.session.failed {
                FinaleOverlay(session: spotlight.session)
                    .transition(.opacity.combined(with: .scale(scale: 1.08)))
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.5), value: model.spotlight)
        .animation(.easeInOut(duration: 0.6), value: chromeVisible)
        .animation(DS.Motion.slow, value: toast)
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            lastMouseMove = Date()
            if !chromeVisible { chromeVisible = true }
        }
        .onReceive(model.pulses) { engine.handle($0) }
        .task {
            // Like a screensaver: after a few still seconds, fade the controls and hide the cursor.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if chromeVisible, Date().timeIntervalSince(lastMouseMove) > 3 {
                    chromeVisible = false
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
        .onAppear {
            engine.preset = prefs.visualizerPreset
            syncPalette()
        }
        .onChange(of: prefs.visualizerPreset) { preset in
            engine.transition(to: preset)
            showToast(preset)
        }
        .onChange(of: model.sessions) { _ in syncPalette() }
    }

    private func showToast(_ preset: VisualizerPreset) {
        toastTask?.cancel()
        toast = preset
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    private func syncPalette() {
        let active = model.active
        engine.isCooking = !active.isEmpty
        engine.palette = Array(Set(active.map(\.agent))).sorted { $0.rawValue < $1.rawValue }.map(\.hue)
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.3), lineWidth: 1))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Bottom-left "now playing" card, in the spirit of iTunes' track info.
private struct NowCookingCard: View {
    let sessions: [AgentSession]

    var body: some View {
        let active = sessions.filter { $0.phase.isActive }
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                if let lead = active.first {
                    Text(isWaiting(lead) ? "WAITING ON YOU" : "NOW COOKING")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(isWaiting(lead) ? DS.Palette.gold : lead.agent.tint)
                    Text(lead.projectName)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(details(lead, now: context.date))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                    if active.count > 1 {
                        Text("+ \(active.count - 1) more on the stove")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                } else {
                    Text("NOTHING ON THE STOVE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Send a prompt to Claude Code or Codex")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.35)))
        }
    }

    private func isWaiting(_ session: AgentSession) -> Bool {
        if case .needsInput = session.phase { return true }
        return false
    }

    private func details(_ session: AgentSession, now: Date) -> String {
        var parts = [session.agent.displayName]
        if let start = session.turnStartedAt { parts.append(Format.clock(now.timeIntervalSince(start))) }
        if session.beats > 0 { parts.append("\(session.beats) step\(session.beats == 1 ? "" : "s")") }
        if let tool = session.lastTool { parts.append(tool) }
        return parts.joined(separator: " · ")
    }
}

private struct FinaleOverlay: View {
    let session: AgentSession
    @State private var popped = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white, session.agent.tint)
                .scaleEffect(popped ? 1 : 0.3)
            Text("Cooked.")
                .font(.system(size: 54, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            if let summary = Format.snippet(session.summary, limit: 160) {
                Text(summary)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
        }
        .padding(40)
        .background(RoundedRectangle(cornerRadius: 28).fill(.black.opacity(0.35)))
        .onAppear {
            withAnimation(DS.Motion.slow) { popped = true }
        }
    }

    private var subtitle: String {
        var text = "\(session.agent.displayName) finished \(session.projectName)"
        if let duration = session.cookDuration { text += " in \(Format.duration(duration))" }
        return text
    }
}
