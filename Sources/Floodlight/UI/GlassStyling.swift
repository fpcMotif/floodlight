import SwiftUI

/// Filter-chip surface: an interactive glass capsule on macOS 26 (unless
/// Reduce Transparency asks for solid material), the frozen macOS 14/15
/// opacity fill everywhere else. Selected vs. unselected only changes fill
/// brightness / glass tint, never shape — chips are already `Capsule()`,
/// so no radius math is needed to stay concentric.
struct FloodlightChipSurface: ViewModifier {
    let isSelected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        // Three paths, not two: glass; macOS 26 with glass suppressed (Reduce
        // Transparency), which is new territory free to gain the Increase
        // Contrast stroke; and genuine macOS 14/15, which #1 freezes pixel
        // -for-pixel — no stroke, no new geometry, ever.
        if #available(macOS 26.0, *) {
            if GlassAvailability.rendersGlass(
                isSupported: true,
                reduceTransparency: reduceTransparency
            ) {
                content
                    .glassEffect(
                        isSelected ? .regular.tint(.primary.opacity(0.14)).interactive() : .regular
                            .interactive(),
                        in: .capsule
                    )
            } else {
                content
                    .background(fallbackFill, in: Capsule())
                    .overlay {
                        if contrast == .increased {
                            Capsule().strokeBorder(
                                .primary.opacity(FloodlightMetrics.increasedContrastStrokeOpacity),
                                lineWidth: 1
                            )
                        }
                    }
            }
        } else {
            content.background(fallbackFill, in: Capsule())
        }
    }

    private var fallbackFill: Color {
        isSelected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.055)
    }
}

/// The selected result row's background: a glass lozenge with a rim light
/// on macOS 26 (unless Reduce Transparency asks for solid material), the
/// frozen opacity-fill highlight everywhere else. Hover and Top Hit keep
/// their existing subtle-brightness/wash treatment in both paths — only
/// the *selected* fill becomes glass. Reuses #28's `resultRowCornerRadius`
/// directly rather than a separate "23pt" figure, so the row's own corners
/// and its selection state never disagree about how round the row is.
struct FloodlightSelectionSurface: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    let fallbackColor: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: FloodlightMetrics.resultRowCornerRadius,
            style: .continuous
        )
        // Same three-path split as FloodlightChipSurface — see its comment.
        if #available(macOS 26.0, *) {
            if isSelected, GlassAvailability.rendersGlass(
                isSupported: true,
                reduceTransparency: reduceTransparency
            ) {
                content
                    .glassEffect(
                        isHovered ? .regular.tint(.primary.opacity(0.08)) : .regular,
                        in: shape
                    )
            } else {
                content
                    .background { shape.fill(fallbackColor) }
                    .overlay {
                        if isSelected, contrast == .increased {
                            shape.strokeBorder(
                                .primary.opacity(FloodlightMetrics.increasedContrastStrokeOpacity),
                                lineWidth: 1
                            )
                        }
                    }
            }
        } else {
            content.background { shape.fill(fallbackColor) }
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
