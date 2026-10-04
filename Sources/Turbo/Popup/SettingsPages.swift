import AppKit
import SwiftUI
import TurboCore

// MARK: - Agents

struct AgentsPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    @State private var claudeConnected = false
    @State private var codexStatus: Integrations.CodexStatus = .notConnected
    @State private var localTest: TestState = .idle
    @State private var errorMessage: String?

    enum TestState: Equatable { case idle, running, passed, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "Agents", subtitle: "Where Turbo listens. Connect what your team uses, local or cloud.")

            CloudAgentCard()

            AgentSetupCard(agent: .claude, status: claudeStatus) {
                if claudeConnected {
                    Menu {
                        Button("Disconnect", role: .destructive) { run { try Integrations.uninstallClaude() } }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Button("Connect") { run { try Integrations.installClaude() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
            } footer: {
                if claudeConnected {
                    HStack(spacing: DS.Space.m) {
                        Button {
                            Task {
                                localTest = .running
                                localTest = await model.testClaudeConnection() ? .passed : .failed
                            }
                        } label: {
                            Text(localTest == .running ? "Testing…" : "Test Connection")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(localTest == .running)
                        testResult(localTest, passed: "Turbo heard it. You're all set.", failed: "No reply. Try quitting and reopening Turbo.", idle: "Start a new Claude Code session after connecting.")
                    }
                }
            }

            AgentSetupCard(agent: .codex, status: watchStatus(.codex, enabled: prefs.watchCodexSessions, present: Integrations.isCodexPresent)) {
                Toggle("Watch Codex", isOn: $prefs.watchCodexSessions).toggleStyle(BCSwitchStyle()).labelsHidden()
            }

            CodexCloudCard()

            AgentSetupCard(agent: .cowork, status: watchStatus(.cowork, enabled: prefs.watchCoworkSessions, present: Integrations.isCoworkPresent)) {
                Toggle("Watch Cowork", isOn: $prefs.watchCoworkSessions).toggleStyle(BCSwitchStyle()).labelsHidden()
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("An optional backup signal for Codex, added to ~/.codex/config.toml. Session watching already covers Codex, so most people don't need this.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    switch codexStatus {
                    case .connected:
                        Button("Remove Notify Hook") { run { try Integrations.uninstallCodex() } }.buttonStyle(SecondaryButtonStyle())
                    case .notConnected:
                        Button("Add Notify Hook") { run { try Integrations.installCodex() } }.buttonStyle(SecondaryButtonStyle())
                    case let .conflict(existing):
                        Callout(symbol: "", text: "You already have a notify program, and Codex allows only one, so Turbo left it alone. To use both, have your script also run the command below.", tone: .attention)
                        Text(existing).font(DS.Typography.mono).textSelection(.enabled)
                        Text("curl -s -m 1 --noproxy '*' -X POST --data-binary \"$1\" http://127.0.0.1:\(HookInstaller.defaultPort)/hook/codex")
                            .font(DS.Typography.mono)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, DS.Space.s)
            } label: {
                Text("Advanced: Codex notify hook").font(DS.Typography.bodyStrong)
            }

            if let errorMessage {
                Callout(symbol: "", text: errorMessage, tone: .bad)
            }
        }
        .onAppear(perform: refresh)
        .animation(DS.Motion.base, value: claudeConnected)
        .animation(DS.Motion.base, value: localTest)
    }

    private var claudeStatus: (String, StatusTone) {
        guard claudeConnected else { return ("Not connected", .neutral) }
        if let heard = model.lastHeard[.claude] { return ("Heard \(relative(heard))", .good) }
        return ("Connected", .good)
    }

    private func watchStatus(_ agent: Agent, enabled: Bool, present: Bool) -> (String, StatusTone) {
        guard enabled else { return ("Off", .neutral) }
        if let heard = model.lastHeard[agent] { return ("Heard \(relative(heard))", .good) }
        return present ? ("Watching", .good) : ("Ready", .neutral)
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update the config: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        claudeConnected = Integrations.isClaudeInstalled
        codexStatus = Integrations.codexStatus
        if !claudeConnected { localTest = .idle }
    }
}

func relative(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    return seconds < 60 ? "just now" : "\(Format.duration(seconds)) ago"
}

@ViewBuilder
func testResult(_ state: AgentsPage.TestState, passed: String, failed: String, idle: String) -> some View {
    switch state {
    case .passed:
        Label(passed, systemImage: "checkmark.circle.fill").foregroundStyle(DS.Palette.ok).font(DS.Typography.caption)
    case .failed:
        Label(failed, systemImage: "xmark.circle.fill").foregroundStyle(DS.Palette.bad).font(DS.Typography.caption)
    default:
        Text(idle).foregroundStyle(DS.Palette.textSecondary).font(DS.Typography.caption)
    }
}

/// Cloud sessions (claude.ai/code): a three-step setup with live status.
private struct CloudAgentCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    @State private var copied = false
    @State private var relayTest: AgentsPage.TestState = .idle
    @State private var confirmReset = false

    var body: some View {
        AgentSetupCard(agent: .cloud, status: status) {
            Toggle("Listen for cloud sessions", isOn: $prefs.cloudEnabled).toggleStyle(BCSwitchStyle()).labelsHidden()
        } footer: {
            if prefs.cloudEnabled {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    step(1, "Copy your setup script. It's tied to your private channel.") {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.cloudSetupScript, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy Setup Script", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    step(2, "In claude.ai/code, open your environment's settings (the environment menu in a session's title bar, then Edit). Paste it at the end of Setup script and save.") {
                        Link(destination: URL(string: "https://claude.ai/code")!) {
                            Text("Open claude.ai/code")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    step(3, "Start a new cloud session. It checks in here right away. If your environment limits network access, add ntfy.sh to its allowed domains.") {
                        Button {
                            Task {
                                relayTest = .running
                                relayTest = await model.testCloudRelay() ? .passed : .failed
                            }
                        } label: {
                            Text(relayTest == .running ? "Testing…" : "Test Relay")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(relayTest == .running)
                    }
                    if relayTest != .idle {
                        testResult(relayTest, passed: "Your Mac is receiving. Cloud sessions will show up as they run.", failed: "Couldn't reach the relay from this Mac. Check your internet connection.", idle: "")
                    }

                    HStack(alignment: .top, spacing: DS.Space.s) {
                        Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(DS.Palette.textTertiary)
                        Text("Pings go through ntfy.sh on a private, random channel. They carry only the event, the repo name and a link to the session. Never your prompts, code or output.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("New Channel") { confirmReset = true }
                            .buttonStyle(GhostButtonStyle())
                            .help("Make a new private channel. You'll need to paste the new setup script.")
                    }
                }
                .confirmationDialog("Make a new channel?", isPresented: $confirmReset) {
                    Button("New Channel", role: .destructive) { model.resetCloudChannel() }
                } message: {
                    Text("Cloud environments using the old setup script will stop reaching this Mac until you paste the new one.")
                }
            }
        }
    }

    private var status: (String, StatusTone) {
        switch model.relayState {
        case .off: return ("Off", .neutral)
        case .connecting: return ("Connecting", .neutral)
        case .retrying: return ("Reconnecting", .attention)
        case .listening:
            if let heard = model.lastHeard[.cloud] { return ("Heard \(relative(heard))", .good) }
            return ("Listening", .good)
        }
    }

    private func step<Action: View>(_ number: Int, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Text("\(number)")
                .font(DSFont.sans(12, .heavy))
                .foregroundStyle(DS.Palette.brandText)
                .frame(width: 22, height: 22)
                .background(Circle().fill(DS.Palette.brandText.opacity(0.15)))
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(text)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }
}

/// Codex cloud: zero setup when the Codex CLI is installed and signed in.
struct CodexCloudCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    @State private var copied = false

    var body: some View {
        AgentSetupCard(agent: .codexCloud, status: status) {
            Toggle("Watch Codex cloud", isOn: $prefs.watchCodexCloud).toggleStyle(BCSwitchStyle()).labelsHidden()
        } footer: {
            if prefs.watchCodexCloud {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    switch model.codexCloudState {
                    case .notInstalled:
                        Text("Install the Codex CLI, then sign in with your ChatGPT account.")
                            .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                        Spacer(minLength: 0)
                        copyButton("brew install codex && codex login")
                    case .notSignedIn:
                        Text("Sign in to the Codex CLI with your ChatGPT account.")
                            .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                        Spacer(minLength: 0)
                        copyButton("codex login")
                    case let .failed(message):
                        Text(message).font(DS.Typography.caption).foregroundStyle(DS.Palette.bad).lineLimit(2)
                        Spacer(minLength: 0)
                    case let .watching(count):
                        Text("Checking \(count) recent task\(count == 1 ? "" : "s") every 20 seconds.")
                            .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                        Spacer(minLength: 0)
                    case .checking, .off:
                        Text("Looking for the Codex CLI…").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                        Spacer(minLength: 0)
                    }
                    Button("Check Now") { model.checkCodexCloudNow() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var status: (String, StatusTone) {
        guard prefs.watchCodexCloud else { return ("Off", .neutral) }
        switch model.codexCloudState {
        case .off, .checking: return ("Checking", .neutral)
        case .watching: return ("Watching", .good)
        case .notInstalled: return ("Needs Codex CLI", .attention)
        case .notSignedIn: return ("Sign in needed", .attention)
        case .failed: return ("Can't reach", .bad)
        }
    }

    private func copyButton(_ command: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

/// An agent with its status, a control, and optional extra content underneath.
struct AgentSetupCard<Accessory: View, Footer: View>: View {
    let agent: Agent
    let status: (String, StatusTone)
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var footer: () -> Footer

    init(agent: Agent, status: (String, StatusTone), @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder footer: @escaping () -> Footer) {
        self.agent = agent
        self.status = status
        self.accessory = accessory
        self.footer = footer
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    IconTile(symbol: agent.symbol, tint: agent.tint, size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: DS.Space.s) {
                            Text(agent.displayName).font(DS.Typography.headline)
                            StatusPill(text: status.0, tone: status.1)
                        }
                        Text(agent.setupBlurb)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.Space.s)
                    accessory()
                }
                footer()
            }
        }
    }
}

extension AgentSetupCard where Footer == EmptyView {
    init(agent: Agent, status: (String, StatusTone), @ViewBuilder accessory: @escaping () -> Accessory) {
        self.init(agent: agent, status: status, accessory: accessory) { EmptyView() }
    }
}

// MARK: - Island

struct IslandPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "Island", subtitle: "The heads-up at the top of your screen: a tiny island while things cook, a bigger one when something lands.")

            SettingsGroup(title: "Placement") {
                SettingRow(title: "Where it appears", detail: placementNote) {
                    Picker("Placement", selection: $prefs.islandPlacement) {
                        ForEach(IslandPlacement.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            SettingsGroup(title: "When something finishes") {
                SettingRow(title: "Celebrate sessions longer than", detail: "Quick ones finish quietly so you're not pinged for every little thing.") {
                    Stepper("\(Int(prefs.minimumCookSeconds)) sec", value: $prefs.minimumCookSeconds, in: 0...300, step: 5)
                        .font(DS.Typography.bodyStrong.monospacedDigit())
                }
                RowDivider()
                SettingRow(title: "Keep the done card up for", detail: "Hovering keeps it open. When several land at once they take turns.") {
                    Stepper("\(Int(prefs.celebrateSeconds)) sec", value: $prefs.celebrateSeconds, in: 2...60, step: 1)
                        .font(DS.Typography.bodyStrong.monospacedDigit())
                }
                RowDivider()
                ToggleRow(title: "Click to jump back", detail: "Clicking a card opens that session: its claude.ai page, or the app it runs in.", isOn: $prefs.returnToTerminalOnClick)
            }

            SettingsGroup(title: "Sound") {
                ToggleRow(title: "Play a sound when done", isOn: $prefs.playSound)
                RowDivider()
                SettingRow(title: "Sound", detail: "Plays once when you pick it.") {
                    Picker("Sound", selection: $prefs.soundName) {
                        ForEach(Preferences.sounds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(!prefs.playSound)
                    .onChange(of: prefs.soundName) { name in NSSound(named: NSSound.Name(name))?.play() }
                }
            }

            HStack(spacing: DS.Space.m) {
                Button("Preview One") { model.closePopup(); model.simulate(.claude) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Preview a Busy Day") { model.closePopup(); model.simulateBusyDay() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var placementNote: String {
        let neighbor = model.neighbors.running.first
        switch prefs.islandPlacement {
        case .automatic:
            if let neighbor { return "\(neighbor) is using the notch, so Turbo floats just below it for now." }
            return "In the notch, moving just below it while another notch app (HeyClicky, NotchNook, Alcove) is running."
        case .notch:
            return neighbor.map { "Grows from the notch. \($0) also uses the notch, so if they overlap, pick Below the notch." } ?? "Grows from the notch, like the iPhone's Dynamic Island."
        case .belowNotch:
            return "Always just below the notch, leaving the notch to other apps."
        }
    }
}

// MARK: - Visualizer

struct VisualizerPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "Visualizer", subtitle: "A fun, full-screen view of your sessions' progress. Every step an agent takes is a beat, and every finished session sets off a finale.")

            HStack(spacing: DS.Space.m) {
                ForEach(VisualizerPreset.allCases) { preset in
                    ChoiceCard(title: preset.title, detail: preset.blurb, selected: prefs.visualizerPreset == preset, action: { prefs.visualizerPreset = preset }) {
                        VisualizerPreview(preset: preset)
                    }
                }
            }

            SettingsGroup(title: "Behavior") {
                ToggleRow(title: "Open automatically when something starts cooking", detail: "Off by default. It's always one click away from the hover list and the pop-up.", isOn: $prefs.visualizerAutoOpen)
                RowDivider()
                ToggleRow(title: "Open in full screen", isOn: $prefs.visualizerFullScreen)
                RowDivider()
                ToggleRow(title: "Close when it's done", detail: "After the finale, hands you back to your session.", isOn: $prefs.visualizerAutoClose)
            }

            Button("Open Visualizer") { model.openVisualizer() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }
}

extension VisualizerPreset {
    var blurb: String {
        switch self {
        case .magnetosphere: return "Glowing swarms"
        case .ribbons: return "Mirrored light trails"
        case .warp: return "Speeding starfield"
        }
    }
}

// MARK: - About

struct AboutPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            HStack(spacing: DS.Space.l) {
                AppIconView(size: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Turbo").font(DS.Typography.display)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · by BetterCampus")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }

            SettingsGroup(title: "General") {
                ToggleRow(title: "Open Turbo when you log in", detail: "So it's always ready.", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                RowDivider()
                SettingRow(title: "Welcome tour", detail: "Walk through setup again.") {
                    Button("Show") { model.showOnboarding() }.buttonStyle(SecondaryButtonStyle())
                }
                RowDivider()
                SettingRow(title: "Update Turbo", detail: "Run the install command again any time to get the latest build.") {
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Integrations.installCommand, forType: .string)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            if let error = model.serverError {
                Callout(symbol: "", text: error, tone: .bad)
            } else {
                Callout(symbol: "", text: "Local sessions never leave your Mac: Turbo listens on 127.0.0.1:\(HookInstaller.defaultPort) and reads agent logs on disk. Cloud sessions send thin pings through a private relay channel.", tone: .good)
            }

            HStack {
                Spacer()
                Button("Quit Turbo") { NSApp.terminate(nil) }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }
}
