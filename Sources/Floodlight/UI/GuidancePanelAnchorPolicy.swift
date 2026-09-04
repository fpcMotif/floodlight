import AppKit
import CoreGraphics
import Foundation

package enum GuidancePanelAnchorPolicy {
    package static func computeFrame(
        targetWindow: NSRect?,
        parentWindow: NSRect?,
        screen: NSRect,
        panelSize: NSSize = NSSize(width: 380, height: 110)
    ) -> NSRect {
        if let target = targetWindow {
            let posX = target.midX - (panelSize.width / 2)
            let posY = target.minY - panelSize.height + 20
            return clamp(
                NSRect(x: posX, y: posY, width: panelSize.width, height: panelSize.height),
                in: screen
            )
        }

        if let parent = parentWindow {
            let posX = parent.midX - (panelSize.width / 2)
            let posY = parent.minY - panelSize.height + 16
            return clamp(
                NSRect(x: posX, y: posY, width: panelSize.width, height: panelSize.height),
                in: screen
            )
        }

        let posX = screen.midX - (panelSize.width / 2)
        let posY = screen.minY + 80
        return clamp(
            NSRect(x: posX, y: posY, width: panelSize.width, height: panelSize.height),
            in: screen
        )
    }

    private static func clamp(_ rect: NSRect, in screen: NSRect) -> NSRect {
        var clamped = rect
        let minX = screen.minX + 12
        let maxX = screen.maxX - rect.width - 12
        let minY = screen.minY + 8
        let maxY = screen.maxY - rect.height - 8

        if clamped.origin.x < minX {
            clamped.origin.x = minX
        } else if clamped.origin.x > maxX {
            clamped.origin.x = maxX
        }

        if clamped.origin.y < minY {
            clamped.origin.y = minY
        } else if clamped.origin.y > maxY {
            clamped.origin.y = maxY
        }

        return clamped
    }
}

@MainActor
package enum SystemSettingsWindowLocator {
    package static func convertToCocoa(
        quartzBounds: CGRect,
        primaryScreenHeight: CGFloat
    ) -> NSRect {
        let cocoaY = primaryScreenHeight - (quartzBounds.origin.y + quartzBounds.height)
        return NSRect(
            x: quartzBounds.origin.x,
            y: cocoaY,
            width: quartzBounds.width,
            height: quartzBounds.height
        )
    }

    package static func locateWindow(
        processNames: [String] = ["System Settings", "System Preferences"],
        bundleIDs: [String] = ["com.apple.systempreferences"]
    ) -> NSRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900

        for window in infoList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }
            guard let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0.5 else {
                continue
            }

            let ownerName = (window[kCGWindowOwnerName as String] as? String) ?? ""
            let matchesProcess = processNames
                .contains { ownerName.localizedCaseInsensitiveContains($0) }

            if matchesProcess {
                if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                   let quartzRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                   quartzRect.width > 100, quartzRect.height > 100
                {
                    return convertToCocoa(
                        quartzBounds: quartzRect,
                        primaryScreenHeight: primaryHeight
                    )
                }
            }
        }

        return nil
    }
}
