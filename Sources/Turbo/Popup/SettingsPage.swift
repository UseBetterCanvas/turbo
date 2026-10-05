import AppKit
import SwiftUI
import TurboCore

/// All settings on one page, in four short sections.
struct SettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            ConnectionsSection()
            IslandSection()
            VisualizerSection()
            GeneralSection()
        }
    }
}

// MARK: - Connections

private struct ConnectionsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    @State private var claudeConnected = Integrations.isClaudeInstalled
    @State private var error: String?

    var body: some View {
        SettingsGroup(title: "Connections") {
            ConnectionRow(agent: .cloud, status: cloudStatus, startsExpanded: prefs.cloudEnabled && model.lastHeard[.cloud] == nil) {
                Toggle("Claude Code cloud", isOn: $prefs.cloudEnabled).toggleStyle(BCSwitchStyle()).labelsHidden()
            } details: {
                if prefs.cloudEnabled { CloudSetupSteps() }
            }
            RowDivider()
            ConnectionRow(agent: .claude, status: claudeStatus, startsExpanded: false) {
                if claudeConnected {
                    EmptyView()
                } else {
                    Button("Connect") { run { try Integrations.installClaude() } }.buttonStyle(PrimaryButtonStyle())
                }
            } details: {
                if claudeConnected { ClaudeLocalDetails(onDisconnect: { run { try Integrations.uninstallClaude() } }) }
            }
            RowDivider()
            ConnectionRow(agent: .codex, status: watch(.codex, prefs.watchCodexSessions), startsExpanded: false) {
                Toggle("Codex", isOn: $prefs.watchCodexSessions).toggleStyle(BCSwitchStyle()).labelsHidden()
            } details: {
                CodexNotifyDetails()
            }
            RowDivider()
            ConnectionRow(agent: .codexCloud, status: codexCloudStatus, startsExpanded: codexCloudNeedsHelp) {
                Toggle("Codex cloud", isOn: $prefs.watchCodexCloud).toggleStyle(BCSwitchStyle()).labelsHidden()
            } details: {
                if prefs.watchCodexCloud { CodexCloudDetails() }
            }
            RowDivider()
            ConnectionRow(agent: .cowork, status: watch(.cowork, prefs.watchCoworkSessions), startsExpanded: false) {
                Toggle("Cowork", isOn: $prefs.watchCoworkSessions).toggleStyle(BCSwitchStyle()).labelsHidden()
            } details: {
                EmptyView()
            }
        }
        if let error { Callout(symbol: "", text: error, tone: .bad) }
    }

    private var cloudStatus: (String, StatusTone) {
        guard prefs.cloudEnabled else { return ("Off", .neutral) }
        switch model.relayState {
        case .off, .connecting: return ("Connecting", .neutral)
        case .retrying: return ("Reconnecting", .attention)
        case .listening:
            if let heard = model.lastHeard[.cloud] { return ("Heard \(relative(heard))", .good) }
            return ("Listening", .good)
        }
    }

    private var claudeStatus: (String, StatusTone) {
        guard claudeConnected else { return ("Not connected", .neutral) }
        if let heard = model.lastHeard[.claude] { return ("Heard \(relative(heard))", .good) }
        return ("Connected", .good)
    }

    private var codexCloudNeedsHelp: Bool {
        guard prefs.watchCodexCloud else { return false }
        switch model.codexCloudState {
        case .notInstalled, .notSignedIn, .failed: return true
        default: return false
        }
    }

    private var codexCloudStatus: (String, StatusTone) {
        guard prefs.watchCodexCloud else { return ("Off", .neutral) }
        switch model.codexCloudState {
        case .off, .checking: return ("Checking", .neutral)
        case .watching: return ("Watching", .good)
        case .notInstalled: return ("Needs Codex CLI", .attention)
        case .notSignedIn: return ("Sign in needed", .attention)
        case .failed: return ("Can't reach", .bad)
        }
    }

    private func watch(_ agent: Agent, _ enabled: Bool) -> (String, StatusTone) {
        guard enabled else { return ("Off", .neutral) }
        if let heard = model.lastHeard[agent] { return ("Heard \(relative(heard))", .good) }
        return ("Watching", .good)
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = "Couldn't update the config: \(error.localizedDescription)"
        }
        claudeConnected = Integrations.isClaudeInstalled
    }
}

/// Icon, name, status and one control. Click the row to show its details, if it has any.
private struct ConnectionRow<Control: View, Details: View>: View {
    let agent: Agent
    let status: (String, StatusTone)
    @ViewBuilder var control: () -> Control
    @ViewBuilder var details: () -> Details
    @State private var expanded: Bool
    @State private var hovering = false

    /// True while the row needs attention; it opens itself when this turns on.
    let needsAttention: Bool

    init(agent: Agent, status: (String, StatusTone), startsExpanded: Bool, @ViewBuilder control: @escaping () -> Control, @ViewBuilder details: @escaping () -> Details) {
        self.agent = agent
        self.status = status
        self.control = control
        self.details = details
        self.needsAttention = startsExpanded
        _expanded = State(initialValue: startsExpanded)
    }

    private var hasDetails: Bool { Details.self != EmptyView.self }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.m) {
                IconTile(symbol: agent.symbol, tint: agent.tint, size: 28)
                Text(agent.displayName).font(DS.Typography.bodyStrong)
                StatusPill(text: status.0, tone: status.1)
                Spacer(minLength: DS.Space.s)
                if hasDetails {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Palette.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                control()
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture { if hasDetails { withAnimation(DS.Motion.base) { expanded.toggle() } } }
            .onChange(of: needsAttention) { attention in
                if attention { withAnimation(DS.Motion.base) { expanded = true } }
            }

            if expanded && hasDetails {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(agent.setupBlurb)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    details()
                }
                .padding(.leading, 40)
                .padding(.bottom, DS.Space.m)
                .transition(.opacity)
            }
        }
    }
}

/// Three steps to get cloud sessions checking in.
private struct CloudSetupSteps: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences
    @State private var copied = false
    @State private var test: TestState = .idle
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if model.cloudScriptOutdated {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(DS.Palette.gold)
                    Text("There's a newer setup script, with Stop and live step details. Copy it and paste it over the old one.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.s)
                .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(DS.Palette.gold.opacity(0.12)))
            }
            step(1, "Copy your setup script.") {
                Button {
                    model.copyCloudSetupScript()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Script", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            step(2, "Paste it at the end of your claude.ai/code environment's Setup script.") {
                Link("Open claude.ai", destination: URL(string: "https://claude.ai/code")!)
                    .buttonStyle(SecondaryButtonStyle())
            }
            step(3, "Start a new cloud session. It shows up here.") {
                Button(test == .running ? "Testing…" : "Test") {
                    Task {
                        test = .running
                        test = await model.testCloudRelay() ? .passed : .failed
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(test == .running)
            }
            if test != .idle {
                testResult(test, passed: "Your Mac is receiving.", failed: "Couldn't reach the relay. Check your connection.")
            }
            HStack(spacing: DS.Space.s) {
                Text("Turbo only gets the event, repo name, session link and Claude's one-line step description. Never your code. If your environment limits network access, allow ntfy.sh.")
                    .font(DSFont.sans(11, .medium))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("New Channel") { confirmReset = true }
                    .buttonStyle(.plain)
                    .font(DSFont.sans(11, .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.top, DS.Space.xs)
            // The switch style draws only the switch, so the words sit beside it.
            HStack(alignment: .center, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name Cloud Sessions").font(DS.Typography.bodyStrong).foregroundStyle(DS.Palette.textPrimary)
                    Text("Show each cloud session by what it was asked, using the first 6 words of the prompt, instead of just the repo name. Copy the script again after changing this.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.m)
                Toggle("Name Cloud Sessions", isOn: $prefs.cloudShareTitles)
                    .toggleStyle(BCSwitchStyle())
                    .labelsHidden()
            }
            .padding(.top, DS.Space.xs)
        }
        .confirmationDialog("Make a new channel?", isPresented: $confirmReset) {
            Button("New Channel", role: .destructive) { model.resetCloudChannel() }
        } message: {
            Text("Environments using the old setup script stop reaching this Mac until you paste the new one.")
        }
    }

    private func step<Action: View>(_ number: Int, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: DS.Space.s) {
            Text("\(number)")
                .font(DSFont.sans(11, .heavy))
                .foregroundStyle(DS.Palette.brandText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(DS.Palette.brandText.opacity(0.15)))
            Text(text).font(DS.Typography.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.s)
            action()
        }
    }
}

private struct ClaudeLocalDetails: View {
    @EnvironmentObject private var model: AppModel
    let onDisconnect: () -> Void
    @State private var test: TestState = .idle
    @State private var approvals = Integrations.isClaudeApprovalInstalled && Integrations.isClaudeStopInstalled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: approvals ? "checkmark.circle.fill" : "hand.raised")
                    .foregroundStyle(approvals ? DS.Palette.ok : DS.Palette.textSecondary)
                Text(approvals
                     ? "Approvals and Stop are on. Allow, Deny or Stop sessions right from the island."
                     : "Allow, Deny or Stop sessions from the island instead of the terminal.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                if !approvals {
                    Button("Turn On") {
                        do {
                            try Integrations.installClaude()
                            approvals = Integrations.isClaudeApprovalInstalled && Integrations.isClaudeStopInstalled
                            model.refreshIntegrations()
                            error = nil
                        } catch {
                            self.error = "Couldn't update Claude Code's settings: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            if let error { Text(error).font(DS.Typography.caption).foregroundStyle(DS.Palette.bad) }
            testRow
        }
    }

    private var testRow: some View {
        HStack(spacing: DS.Space.s) {
            Button(test == .running ? "Testing…" : "Test Connection") {
                Task {
                    test = .running
                    test = await model.testClaudeConnection() ? .passed : .failed
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(test == .running)
            if test != .idle {
                testResult(test, passed: "Working.", failed: "No reply. Try reopening Turbo.")
            } else {
                Text("Start a new Claude Code session after connecting.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            Button("Disconnect", action: onDisconnect)
                .buttonStyle(.plain)
                .font(DSFont.sans(12, .semibold))
                .foregroundStyle(DS.Palette.bad)
        }
    }
}

private struct CodexCloudDetails: View {
    @EnvironmentObject private var model: AppModel
    @State private var copied = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            switch model.codexCloudState {
            case .notInstalled:
                hint("Install the Codex CLI and sign in.")
                copyButton("brew install codex && codex login")
            case .notSignedIn:
                hint("Sign in to the Codex CLI.")
                copyButton("codex login")
            case let .failed(message):
                Text(message).font(DS.Typography.caption).foregroundStyle(DS.Palette.bad).lineLimit(2)
                Spacer(minLength: 0)
            case let .watching(count):
                hint("Checking \(count) recent task\(count == 1 ? "" : "s") every 20 seconds.")
            case .checking, .off:
                hint("Looking for the Codex CLI…")
            }
            Button("Check Now") { model.checkCodexCloudNow() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func hint(_ text: String) -> some View {
        HStack {
            Text(text).font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func copyButton(_ command: String) -> some View {
        Button {
            copy(command)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

/// The optional Codex notify hook, tucked under the Codex row.
private struct CodexNotifyDetails: View {
    @State private var status: Integrations.CodexStatus = Integrations.codexStatus
    @State private var error: String?
    @State private var copied = false

    static let chainCommand = "curl -s -m 1 --noproxy '*' -X POST --data-binary \"$1\" http://127.0.0.1:\(HookInstaller.defaultPort)/hook/codex"

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                switch status {
                case .connected:
                    Text("Backup notify hook is on.").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                    Spacer()
                    Button("Remove") { run { try Integrations.uninstallCodex() } }
                        .buttonStyle(SecondaryButtonStyle())
                case .notConnected:
                    Text("Optional: add a backup notify hook to ~/.codex/config.toml.").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                    Spacer()
                    Button("Add") { run { try Integrations.installCodex() } }
                        .buttonStyle(SecondaryButtonStyle())
                case .conflict:
                    Text("You already have a Codex notify program, and Codex allows only one. To use both, have your program also run this command.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DS.Space.s)
                    Button(copied ? "Copied" : "Copy Command") {
                        copy(Self.chainCommand)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            if let error {
                Text(error).font(DS.Typography.caption).foregroundStyle(DS.Palette.bad)
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = "Couldn't update ~/.codex/config.toml: \(error.localizedDescription)"
        }
        status = Integrations.codexStatus
    }
}

// MARK: - Island

private struct IslandSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        SettingsGroup(title: "Island") {
            SettingRow(title: "Placement", detail: placementNote) {
                Picker("Placement", selection: $prefs.islandPlacement) {
                    ForEach(IslandPlacement.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            RowDivider()
            SettingRow(title: "Announce sessions longer than", detail: "Quicker ones finish quietly.") {
                Stepper("\(Int(prefs.minimumCookSeconds)) sec", value: $prefs.minimumCookSeconds, in: 0...300, step: 5)
                    .font(DS.Typography.bodyStrong.monospacedDigit())
            }
            RowDivider()
            SettingRow(title: "Keep the done card up for", detail: "Hovering keeps it open.") {
                Stepper("\(Int(prefs.celebrateSeconds)) sec", value: $prefs.celebrateSeconds, in: 2...60, step: 1)
                    .font(DS.Typography.bodyStrong.monospacedDigit())
            }
            RowDivider()
            ToggleRow(title: "Click a Card to Open Its Session", isOn: $prefs.returnToTerminalOnClick)
            RowDivider()
            ToggleRow(title: "Show Each New Step", detail: "The tiny island grows for a moment to show what the session it tracks is doing now.", isOn: $prefs.showStepPeeks)
            RowDivider()
            SettingRow(title: "Sound when done") {
                HStack(spacing: DS.Space.s) {
                    if prefs.playSound {
                        Picker("Sound", selection: $prefs.soundName) {
                            ForEach(Preferences.sounds, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        .onChange(of: prefs.soundName) { name in NSSound(named: NSSound.Name(name))?.play() }
                    }
                    Toggle("Sound", isOn: $prefs.playSound).toggleStyle(BCSwitchStyle()).labelsHidden()
                }
            }
            RowDivider()
            HStack(spacing: DS.Space.m) {
                Text("Preview").font(DS.Typography.bodyStrong)
                Spacer()
                Button("One Session") { model.closePopup(); model.simulate(.claude) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Busy Day") { model.closePopup(); model.simulateBusyDay() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.vertical, 12)
        }
    }

    private var placementNote: String? {
        guard let neighbor = model.neighbors.running.first else { return nil }
        switch prefs.islandPlacement {
        case .notch: return "\(neighbor) also uses the notch. If they overlap, pick Below the notch."
        case .automatic: return "Floating below the notch while \(neighbor) is running."
        case .belowNotch: return nil
        }
    }
}

// MARK: - Visualizer

private struct VisualizerSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        SettingsGroup(title: "Visualizer") {
            SettingRow(title: "Look") {
                BCSegmented(options: VisualizerPreset.allCases.map { SegmentOption(value: $0, label: $0.title) }, selection: $prefs.visualizerPreset)
                    .frame(width: 300)
            }
            RowDivider()
            ToggleRow(title: "Open Automatically When Something Starts", isOn: $prefs.visualizerAutoOpen)
            RowDivider()
            ToggleRow(title: "Move With Your Music", detail: musicNote, isOn: $prefs.visualizerListens)
            RowDivider()
            ToggleRow(title: "Full Screen", isOn: $prefs.visualizerFullScreen)
            RowDivider()
            ToggleRow(title: "Close When It's Done", isOn: $prefs.visualizerAutoClose)
        }
    }

    private var musicNote: String {
        switch model.musicState {
        case let .listening(app): return "Listening to \(app ?? "your Mac"). Works with speakers and AirPods."
        case .needsPermission: return "Allow Turbo under System Settings → Privacy & Security → Screen Recording. Turbo only reads the sound."
        case let .failed(message): return "Couldn't listen: \(message)"
        default: return "Pulses to Spotify or whatever's playing. macOS asks for Screen Recording permission once; Turbo only reads the sound."
        }
    }
}

// MARK: - General

private struct GeneralSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: Preferences

    private var openHint: String {
        guard prefs.openSessionsIn == .app else { return "Opens claude.ai or chatgpt.com in your browser." }
        let claude = AppModel.appInstalled(for: .cloud)
        let chatgpt = AppModel.appInstalled(for: .codexCloud)
        switch (claude, chatgpt) {
        case (true, true): return "Claude sessions open in the Claude app, Codex tasks in the ChatGPT app."
        case (true, false): return "Claude sessions open in the Claude app. Codex tasks open in the browser (no ChatGPT app found)."
        case (false, true): return "Codex tasks open in the ChatGPT app. Claude sessions open in the browser (no Claude app found)."
        case (false, false): return "Neither the Claude nor the ChatGPT app is installed, so sessions open in the browser."
        }
    }

    var body: some View {
        SettingsGroup(title: "General") {
            SettingRow(title: "Open cloud sessions in", detail: openHint) {
                BCSegmented(options: OpenTarget.allCases.map { SegmentOption(value: $0, label: $0.title) }, selection: $prefs.openSessionsIn)
                    .frame(width: 180)
            }
            RowDivider()
            ToggleRow(title: "Open at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            RowDivider()
            UpdateRow(updater: model.updater)
            RowDivider()
            ToggleRow(title: "Install Updates Automatically", isOn: $prefs.autoUpdate)
            RowDivider()
            SettingRow(title: "Welcome Tour") {
                Button("Show") { model.showOnboarding() }.buttonStyle(SecondaryButtonStyle())
            }
        }

        HStack {
            Text("Turbo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · BetterCampus")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Palette.textTertiary)
            Spacer()
            Button("Quit Turbo") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(DSFont.sans(12, .semibold))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(.horizontal, DS.Space.xs)
    }
}

/// "Update" lives here: status on the left, one button on the right.
struct UpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        SettingRow(title: "Updates", detail: detail) {
            switch updater.state {
            case .available:
                Button("Update") { Task { await updater.install() } }
                    .buttonStyle(PrimaryButtonStyle())
            case .checking, .downloading, .installing:
                ProgressView().controlSize(.small)
            case .needsAccess:
                HStack(spacing: DS.Space.s) {
                    Button("Check Again") { Task { await updater.check() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            case .manualInstall:
                Button("Copy Install Command") { copy(Integrations.installCommand) }
                    .buttonStyle(PrimaryButtonStyle())
            case .translocated:
                Button("Fix and Relaunch") { updater.fixTranslocation() }
                    .buttonStyle(PrimaryButtonStyle())
            default:
                Button("Check Now") { Task { await updater.check() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var detail: String {
        switch updater.state {
        case .idle: return "Turbo checks every hour and installs new versions when nothing's cooking."
        case .checking: return "Checking…"
        case .upToDate: return "You're on the latest version."
        case .available: return "A new version is ready. Turbo will reopen after updating."
        case .downloading: return "Downloading…"
        case .installing: return "Installing. Turbo will reopen in a moment."
        // GitHub turned the check away: usually its hourly limit for anonymous checks.
        case .needsAccess: return "GitHub isn't answering update checks right now (it limits how often Macs can check). Turbo tries again on its own within the hour."
        case let .manualInstall(message): return message
        case .translocated: return "macOS is running Turbo from a temporary copy, so it can't update itself. Fix it once and Turbo reopens from Applications."
        case let .failed(message): return message
        }
    }
}

// MARK: - Shared helpers

enum TestState: Equatable { case idle, running, passed, failed }

func relative(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    return seconds < 60 ? "just now" : "\(Format.duration(seconds)) ago"
}

@ViewBuilder
func testResult(_ state: TestState, passed: String, failed: String) -> some View {
    switch state {
    case .passed:
        Label(passed, systemImage: "checkmark.circle.fill").foregroundStyle(DS.Palette.ok).font(DS.Typography.caption)
    case .failed:
        Label(failed, systemImage: "xmark.circle.fill").foregroundStyle(DS.Palette.bad).font(DS.Typography.caption)
    default:
        EmptyView()
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// An agent with its status, a control, and optional content underneath (used by the welcome tour).
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
        Card(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    IconTile(symbol: agent.symbol, tint: agent.tint, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
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
