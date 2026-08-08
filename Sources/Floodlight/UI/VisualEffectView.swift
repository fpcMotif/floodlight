import AppKit
import SwiftUI

struct FloodlightSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        // The real glass slab (NSGlassEffectView, in FloodlightPanel) already
        // sits behind this content on macOS 26 with transparency allowed —
        // this modifier only needs to supply a background when that slab
        // isn't there, whether because the OS predates 26 or because Reduce
        // Transparency forced the same solid-material fallback FloodlightPanel
        // uses. Both reasons resolve through the one shared decision.
        if #available(macOS 26.0, *),
           GlassAvailability.rendersGlass(isSupported: true, reduceTransparency: reduceTransparency) {
            content
        } else {
            content.background {
                VisualEffectView(
                    material: .hudWindow,
                    blendingMode: .behindWindow
                )
            }
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
