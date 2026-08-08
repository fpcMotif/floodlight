import AppKit
import SwiftUI

private extension Color {
    static let floodlightSetupAccent = Color(
        red: 0.72,
        green: 0.49,
        blue: 0.32
    )
}

struct OnboardingView: View {
    let presentation: FloodlightConfigurationPresentation
    @Bindable var session: OnboardingSession
    // Every callback carries its isolation. `onSetLaunchAtLogin` has to,
    // because it drives a `Binding`'s setter and SwiftUI now requires that
    // setter to be `@isolated(any) @Sendable`; the rest are annotated to match
    // rather than leaving one of six spelled differently for a reason that is
    // invisible at the declaration. Every caller is a main-actor controller
    // already, so this only writes down what was true.
    let onSelectShortcut: @MainActor @Sendable (FloodlightShortcut) -> Void
    let onSetLaunchAtLogin: @MainActor @Sendable (Bool) -> Void
    let onChooseScope: @MainActor @Sendable () -> Void
    let onOpenSpotlightSettings: @MainActor @Sendable () -> Void
    let onOpenFullDiskAccess: @MainActor @Sendable () -> Void
    let onFinish: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VStack(spacing: 14) {
                shortcutSection
                searchAccessSection
                Spacer(minLength: 0)
            }
            .padding(20)

            Divider()
            footer
        }
        .frame(width: 760, height: 530)
        .background(Color(red: 0.065, green: 0.067, blue: 0.075))
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "flashlight.on.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.floodlightSetupAccent)
                .frame(width: 44, height: 44)
                .background(
                    Color.floodlightSetupAccent.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 22, weight: .semibold))
                Text(presentation.subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 82)
    }

    private var shortcutSection: some View {
        SetupSection(title: "General") {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keyboard shortcut")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Open Floodlight from any app.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    ShortcutPreview(shortcut: session.activeShortcut)
                }
                .padding(.vertical, 12)

                HStack(spacing: 8) {
                    ForEach(FloodlightShortcut.allCases) { shortcut in
                        Button {
                            onSelectShortcut(shortcut)
                        } label: {
                            Label(
                                shortcut.displayName,
                                systemImage: session.activeShortcut == shortcut
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                        }
                        .buttonStyle(.bordered)
                        .tint(
                            session.activeShortcut == shortcut
                                ? Color.floodlightSetupAccent
                                : nil
                        )
                    }

                    Spacer()

                    if session.offersSpotlightReplacement {
                        Button("Replace Spotlight…", action: onOpenSpotlightSettings)
                            .buttonStyle(.link)
                            .help("Open macOS Spotlight shortcut settings")
                    }
                }
                .padding(.bottom, 12)

                if let message = session.shortcutMessage {
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.floodlightSetupAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 12)
                }

                Divider()

                SetupRow(
                    icon: "power",
                    title: "Open at login",
                    subtitle: "Keep Floodlight ready after you sign in."
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { session.launchesAtLogin },
                            set: onSetLaunchAtLogin
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Color.floodlightSetupAccent)
                }

                if let message = session.launchAtLoginMessage {
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.floodlightSetupAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private var searchAccessSection: some View {
        SetupSection(title: "Search access") {
            VStack(spacing: 0) {
                SetupRow(
                    icon: "scope",
                    title: "Search scope",
                    subtitle: session.rootURL.path
                ) {
                    Button("Choose…", action: onChooseScope)
                        .buttonStyle(.bordered)
                }

                Divider()

                SetupRow(
                    icon: "externaldrive.fill",
                    title: "Full Disk Access",
                    subtitle: "Index protected locations throughout your search scope."
                ) {
                    if session.hasFullDiskAccess {
                        HStack(spacing: 10) {
                            Label("Granted", systemImage: "checkmark")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)

                            Button("Revoke…", action: onOpenFullDiskAccess)
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Button("Grant access", action: onOpenFullDiskAccess)
                            .buttonStyle(.bordered)
                            .tint(Color.floodlightSetupAccent)
                    }
                }

                Text("Required for complete results. macOS remembers this approval.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button(action: onFinish) {
                Text("Done")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .padding(.horizontal, 19)
                    .frame(height: 32)
                    .background(
                        Color.floodlightSetupAccent,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .frame(height: 58)
    }
}

private struct SetupSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            content()
                .padding(.horizontal, 16)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                }
        }
    }
}

private struct ShortcutPreview: View {
    let shortcut: FloodlightShortcut

    var body: some View {
        HStack(spacing: 7) {
            KeyCap(symbol: shortcut.modifierSymbol, width: 54)
            Text("+")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
            KeyCap(symbol: "space", width: 112)
        }
    }
}

private struct KeyCap: View {
    let symbol: String
    let width: CGFloat

    var body: some View {
        Text(symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: width, height: 34)
            .background(
                Color.primary.opacity(0.065),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
    }
}

private struct SetupRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 14)
            trailing()
        }
        .frame(minHeight: 50)
    }
}
