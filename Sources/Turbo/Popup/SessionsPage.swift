import SwiftUI
import TurboCore

/// Shown on the board when a new version is ready.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if case .translocated = updater.state {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Palette.gold)
                Text("macOS is running Turbo from a temporary copy, so it can't update. Fix it once.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Fix and Relaunch") { updater.fixTranslocation() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.card))
        } else if case let .manualInstall(message) = updater.state {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Palette.gold)
                Text(message)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Copy Install Command") { copy(Integrations.installCommand) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.card))
        } else if updater.updateAvailable || updater.installError != nil {
            HStack(spacing: DS.Space.m) {
                Image(systemName: updater.installError == nil ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(updater.installError == nil ? DS.Palette.brandText : DS.Palette.bad)
                VStack(alignment: .leading, spacing: 2) {
                    Text(updater.installError == nil ? "A new version of Turbo is ready." : "The update didn't finish.")
                        .font(DS.Typography.bodyStrong)
                    if let error = updater.installError {
                        Text(error).font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                    }
                }
                Spacer()
                if updater.installError != nil {
                    Button("Try Again") { Task { await updater.retryInstall() } }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Update") { Task { await updater.install() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.card))
        }
    }
}

/// A slim one-line prompt until something is connected.
struct SetupBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.brandText)
            Text("Connect your agents so Turbo can hear them.")
                .font(DS.Typography.bodyStrong)
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer()
            Button("Set Up") { model.popupPage = .settings }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.brand.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(DS.Palette.brand.opacity(0.35), lineWidth: 1))
    }
}
