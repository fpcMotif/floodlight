import AppKit
import SwiftUI

package struct FullDiskAccessGuidanceView: View {
    package let phase: FullDiskAccessGrantPhase
    package let appName: String
    package let onDismiss: () -> Void

    package init(
        phase: FullDiskAccessGrantPhase,
        appName: String = "Floodlight",
        onDismiss: @escaping () -> Void = {}
    ) {
        self.phase = phase
        self.appName = appName
        self.onDismiss = onDismiss
    }

    package var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            contentView
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(width: 380, height: 110)
    }

    @ViewBuilder
    private var contentView: some View {
        switch phase {
        case let .presentingGuidance(appURL, _):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    Text("Drag \(appName) into the Full Disk Access list")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 4)

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                draggableAppCard(appURL: appURL)

                Text("Or click + in System Settings and choose \(appName)")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.tertiary)
            }

        case .granted:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access Granted")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("You're ready to search everywhere.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)

        case .idle, .dismissed:
            EmptyView()
        }
    }

    private func draggableAppCard(appURL: URL) -> some View {
        HStack(spacing: 8) {
            if let icon = NSApp?.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
            }
            Text(appName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .draggable(appURL)
    }
}

@MainActor
package final class FullDiskAccessGuidancePanel: NSPanel {
    private let coordinator: FullDiskAccessGrantCoordinator
    private var hostingView: NSHostingView<FullDiskAccessGuidanceView>?

    package init(
        coordinator: FullDiskAccessGrantCoordinator,
        appURL: URL
    ) {
        self.coordinator = coordinator

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        updatePhase(.presentingGuidance(appURL: appURL, isPolling: true))
    }

    package func show(targetRect: NSRect? = nil, parentRect: NSRect? = nil) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let frame = GuidancePanelAnchorPolicy.computeFrame(
            targetWindow: targetRect,
            parentWindow: parentRect,
            screen: screen,
            panelSize: NSSize(width: 380, height: 110)
        )
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    package func updateAnchorFrame(targetRect: NSRect?, parentRect: NSRect?, animate: Bool = true) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let newFrame = GuidancePanelAnchorPolicy.computeFrame(
            targetWindow: targetRect,
            parentWindow: parentRect,
            screen: screen,
            panelSize: NSSize(width: 380, height: 110)
        )
        if abs(newFrame.origin.x - frame.origin.x) > 4 || abs(newFrame.origin.y - frame.origin.y) >
            4
        {
            setFrame(newFrame, display: true, animate: animate)
        }
    }

    package func updatePhase(_ phase: FullDiskAccessGrantPhase) {
        let view = FullDiskAccessGuidanceView(
            phase: phase,
            appName: "Floodlight",
            onDismiss: { [weak self] in
                self?.coordinator.dismiss()
            }
        )
        if let existing = hostingView {
            existing.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 110)
            contentView = hosting
            hostingView = hosting
        }
    }
}
