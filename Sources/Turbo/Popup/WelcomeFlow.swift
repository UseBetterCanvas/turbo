import AppKit
import SwiftUI
import TurboCore

/// First run, inside the pop-up: what Turbo is, how to be told, connect, see it work.
struct WelcomeFlow: View {
    @EnvironmentObject private var model: AppModel
    @State private var step = 0
    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: WelcomeIntro()
                case 1: WelcomeMode()
                case 2: WelcomeConnect()
                default: WelcomeTry()
                }
            }
            .id(step)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 56)
            .padding(.top, DS.Space.l)

            footer
        }
        .background(DS.Palette.base)
        .animation(DS.Motion.base, value: step)
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(GhostButtonStyle())
            } else {
                Button("Skip") { model.finishOnboarding() }
                    .buttonStyle(GhostButtonStyle())
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? DS.Palette.brand : DS.Palette.border)
                        .frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            Spacer()
            if step < steps - 1 {
                Button(step == 0 ? "Get Started" : "Continue") { step += 1 }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { model.finishOnboarding() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.m)
        .background(DS.Palette.rail)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.divider).frame(height: 1) }
    }
}

private struct WelcomeIntro: View {
    var body: some View {
        VStack(spacing: DS.Space.l) {
            Spacer(minLength: 0)
            AppIconView(size: 104)
            Text("Meet Turbo")
                .font(DSFont.display(40))
                .tracking(-1.2)
            Text("Run a bunch of AI sessions at once and stop babysitting them.\nTurbo watches them all and taps you, right in the notch, the moment one finishes or needs you.")
                .font(DSFont.sans(15))
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.xl) {
                Feature(symbol: "square.stack.3d.up", title: "Every session", text: "Local or cloud, in one place")
                Feature(symbol: "hand.raised", title: "Needs you", text: "See who's waiting first")
                Feature(symbol: "arrow.up.forward.app", title: "One click", text: "Jump straight to the thread")
            }
            .padding(.top, DS.Space.s)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private struct Feature: View {
        let symbol: String
        let title: String
        let text: String

        var body: some View {
            VStack(spacing: 6) {
                IconTile(symbol: symbol, tint: DS.Palette.brandText, size: 38)
                Text(title).font(DS.Typography.bodyStrong)
                Text(text)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 150)
        }
    }
}

private struct WelcomeMode: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "How should Turbo tell you?", subtitle: "You can switch any time on the Sessions page.")
            HStack(spacing: DS.Space.l) {
                ChoiceCard(
                    title: "Island",
                    detail: "A quiet heads-up in the notch when a session finishes or needs you.",
                    selected: prefs.mode == .island,
                    action: { prefs.mode = .island }
                ) { IslandPreview() }
                ChoiceCard(
                    title: "Visualizer",
                    detail: "The island, plus a full-screen light show that dances while your agents work.",
                    selected: prefs.mode == .visualizer,
                    action: { prefs.mode = .visualizer }
                ) { VisualizerPreview() }
            }
        }
    }
}

private struct WelcomeConnect: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    @State private var claudeConnected = Integrations.isClaudeInstalled
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            PageHeader(title: "Connect your agents", subtitle: "Turn on what your team uses. You can change this later under Agents.")

            AgentSetupCard(agent: .cloud, status: prefs.cloudEnabled ? ("On", .good) : ("Off", .neutral)) {
                Toggle("Cloud", isOn: $prefs.cloudEnabled).toggleStyle(BCSwitchStyle()).labelsHidden()
            } footer: {
                if prefs.cloudEnabled {
                    HStack(spacing: DS.Space.m) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.cloudSetupScript, forType: .string)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy Setup Script", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        Text("Paste it into your claude.ai/code environment's Setup script.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
            }

            AgentSetupCard(agent: .claude, status: claudeConnected ? ("Connected", .good) : ("Not connected", .neutral)) {
                if claudeConnected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(DS.Palette.ok)
                } else {
                    Button("Connect") { connect() }.buttonStyle(PrimaryButtonStyle())
                }
            }

            HStack(spacing: DS.Space.m) {
                compact(.codex, ready: Integrations.isCodexPresent)
                compact(.cowork, ready: Integrations.isCoworkPresent)
            }

            if let error {
                Callout(symbol: "", text: error, tone: .bad)
            }
        }
        .animation(DS.Motion.base, value: prefs.cloudEnabled)
        .animation(DS.Motion.base, value: claudeConnected)
    }

    private func compact(_ agent: Agent, ready: Bool) -> some View {
        Card(padding: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                IconTile(symbol: agent.symbol, tint: agent.tint, size: 28)
                Text(agent.displayName).font(DS.Typography.bodyStrong)
                Spacer()
                StatusPill(text: ready ? "Ready" : "Ready when used", tone: ready ? .good : .neutral)
            }
        }
    }

    private func connect() {
        do {
            try Integrations.installClaude()
            claudeConnected = Integrations.isClaudeInstalled
            error = nil
        } catch {
            self.error = "Couldn't update Claude Code's settings: \(error.localizedDescription)"
        }
    }
}

private struct WelcomeTry: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            PageHeader(title: "See it in action", subtitle: "Play a pretend busy afternoon: four sessions, one needs you. Watch the notch.")

            Card {
                HStack(spacing: DS.Space.l) {
                    IslandPreview()
                        .frame(width: 210, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        Text("The island shows how many are cooking. Finished ones take turns saying so. Click the paw in your menu bar any time for the full board.")
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            model.finishOnboarding()
                            model.closePopup()
                            model.simulateBusyDay()
                        } label: {
                            Label("Play a Busy Day", systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }

            SettingsGroup {
                ToggleRow(title: "Open Turbo when you log in", detail: "So it's always ready.", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; model.setLaunchAtLogin($0) }
                ))
            }
        }
        .onAppear { launchAtLogin = model.launchAtLogin }
    }
}
