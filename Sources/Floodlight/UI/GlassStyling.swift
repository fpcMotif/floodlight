import SwiftUI

/// Filter-chip surface above the panel's single glass slab. Semantic fills
/// preserve selection without nesting glass effects; Increase Contrast adds a
/// crisp edge.
struct FloodlightChipSurface: ViewModifier {
    let isSelected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(fallbackFill, in: Capsule())
            .overlay { chipBorder }
    }

    private var fallbackFill: Color {
        isSelected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.055)
    }

    @ViewBuilder
    private var chipBorder: some View {
        if contrast == .increased {
            Capsule()
                .strokeBorder(
                    .primary.opacity(FloodlightMetrics.increasedContrastStrokeOpacity),
                    lineWidth: 1
                )
        }
    }
}

/// Row selection above the panel's glass slab. The caller supplies the
/// semantic hover/selection fill; Increase Contrast adds a border.
struct FloodlightSelectionSurface: ViewModifier {
    let isSelected: Bool
    let fallbackColor: Color
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: FloodlightMetrics.resultRowCornerRadius,
            style: .continuous
        )
        content
            .background { shape.fill(fallbackColor) }
            .overlay { selectionBorder(in: shape) }
    }

    @ViewBuilder
    private func selectionBorder(in shape: some InsettableShape) -> some View {
        if isSelected, contrast == .increased {
            shape.strokeBorder(
                Color.primary.opacity(FloodlightMetrics.increasedContrastStrokeOpacity),
                lineWidth: 1
            )
        }
    }
}

/// Results fade softly under the chip bar while scrolling on macOS 26,
/// instead of clipping hard against it. No fallback styling needed below
/// 26 — the modifier simply doesn't apply, leaving today's hard clip.
struct FloodlightScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}
