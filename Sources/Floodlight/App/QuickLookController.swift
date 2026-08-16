import AppKit
import QuickLookUI

@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    private var previewURL: URL?

    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, previewURL == url {
            panel.orderOut(nil)
            return
        }

        previewURL = url
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        QLPreviewPanel.shared()?.orderOut(nil)
        previewURL = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> any QLPreviewItem {
        // QLPreviewPanelDataSource is untyped; AppKit invokes this on the main thread.
        MainActor.assumeIsolated {
            (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
        }
    }
}
