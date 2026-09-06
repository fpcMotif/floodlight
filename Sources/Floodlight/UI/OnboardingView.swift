import AppKit

// periphery:ignore - Module import required for FloodlightEngine types.
import FloodlightEngine
import SwiftUI

private extension Color {
    static let floodlightSetupAccent = Color(
        red: 0.72,
        green: 0.49,
        blue: 0.32
    )
}

@MainActor
struct OnboardingView: View {
    let presentation: FloodlightConfigurationPresentation
    @Bindable var session: OnboardingSession
    @State private var newExclusionName = ""
    @State private var newClipboardExclusion = ""
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

    /// Passing `onSetLaunchAtLogin` straight into `Binding(set:)` asks IRGen
    /// for an `@isolated(any)` reabstraction thunk that overflows SmallVector
    /// on Swift 6.3.3. The wrapper keeps the same callback contract.
    private var launchesAtLogin: Binding<Bool> {
        Binding(
            get: { session.launchesAtLogin },
            set: { newValue in
                onSetLaunchAtLogin(newValue)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    shortcutSection
                    searchAccessSection
                    if presentation == .settings {
                        blocklistSection
                        clipboardSection
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
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
                    if let activeShortcut = session.activeShortcut {
                        ShortcutPreview(shortcut: activeShortcut)
                    } else {
                        Text("Not active")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
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
                        isOn: launchesAtLogin
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
                        HStack(spacing: 8) {
                            inlineDraggableBadge
                            Button("Grant access", action: onOpenFullDiskAccess)
                                .buttonStyle(.bordered)
                                .tint(Color.floodlightSetupAccent)
                        }
                    }
                }

                Text("Drag Floodlight into System Settings, or click Grant access.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
            }
        }
    }

    private var inlineDraggableBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "hand.draw")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Drag")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .draggable(Bundle.main.bundleURL)
        .help("Drag Floodlight directly into System Settings > Full Disk Access")
    }

    private var blocklistSection: some View {
        SetupSection(title: "Excluded search items") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("App name to exclude (e.g. Clash)", text: $newExclusionName)
                        .textFieldStyle(.roundedBorder)
                    Button("Exclude") {
                        let trimmed = newExclusionName
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        session.blockItem(name: trimmed)
                        newExclusionName = ""
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.floodlightSetupAccent)
                    .disabled(newExclusionName.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty)
                }

                if session.blocklistRules.isEmpty {
                    Text("No excluded apps. Excluded applications will not appear in search.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(session.blocklistRules, id: \.self) { rule in
                                HStack(spacing: 5) {
                                    Text(ruleDisplayName(rule))
                                        .font(.system(size: 12, weight: .medium))
                                    Button {
                                        session.unblockRule(rule)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08), in: Capsule())
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var clipboardSection: some View {
        SetupSection(title: "Clipboard History") {
            VStack(alignment: .leading, spacing: 10) {
                SetupRow(
                    icon: "doc.on.clipboard",
                    title: "Record clipboard history",
                    subtitle: "Store copied text locally for instant search and restore."
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { session.clipboardHistoryEnabled },
                            set: { session.clipboardHistoryEnabled = $0 }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Color.floodlightSetupAccent)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("History retention")
                            .font(.system(size: 13, weight: .medium))
                        Text("Unpinned entries older than this duration are pruned.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { session.clipboardRetentionDays },
                        set: { session.clipboardRetentionDays = $0 }
                    )) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("Forever").tag(ClipboardRetention.forever.defaultsValue)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                .padding(.vertical, 4)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Excluded applications")
                        .font(.system(size: 13, weight: .medium))
                    Text("Nothing copied from these app bundle IDs or names will be recorded.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField(
                            "App bundle ID (e.g. com.1password.1password)",
                            text: $newClipboardExclusion
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("Exclude") {
                            let trimmed = newClipboardExclusion
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            session.excludeClipboardApp(bundleID: trimmed)
                            newClipboardExclusion = ""
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.floodlightSetupAccent)
                        .disabled(newClipboardExclusion
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if session.clipboardExclusions.isEmpty {
                        Text("No excluded apps.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(session.clipboardExclusions, id: \.self) { bundleID in
                                    HStack(spacing: 5) {
                                        Text(bundleID)
                                            .font(.system(size: 12, weight: .medium))
                                        Button {
                                            session.unexcludeClipboardApp(bundleID: bundleID)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                Divider()

                HStack {
                    Text("Clear history")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Clear all history…") {
                        session.clearClipboardHistory()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            .padding(.vertical, 6)
        }
    }

    private func ruleDisplayName(_ rule: BlocklistRule) -> String {
        switch rule {
        case let .name(name): name
        case let .id(id): id.replacingOccurrences(of: "application:", with: "")
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
