import CoreGraphics
import FloodlightEngine
import SwiftUI

enum FloodlightMetrics {
    static let panelWidth: CGFloat = 680
    static let searchHeight: CGFloat = 60
    static let filterBarHeight: CGFloat = 40
    static let cornerRadius: CGFloat = searchHeight / 2
    static let resultRowHeight: CGFloat = 58
    static let resultPadding: CGFloat = 7
    static let maximumVisibleResults = 7

    // MARK: - Clipboard board (#57)

    /// The 360 pt list column of the clipboard board's well.
    static let clipboardListWidth: CGFloat = 360
    /// The inspector column of the clipboard board's well — whatever the
    /// panel width leaves once the well's side insets, the list column, and
    /// the 1 pt divider between the two columns are accounted for:
    /// `840 - 14 - 360 - 1 = 465`. Also the render width the inspector's own
    /// snapshot tests mount it at.
    static let clipboardInspectorWidth: CGFloat = 465
    /// The clipboard board's total panel width: the well's two columns and
    /// their divider, plus the well's leading and trailing insets outside
    /// them.
    static let clipboardPanelWidth: CGFloat =
        clipboardListWidth + 1 + clipboardInspectorWidth + clipboardWellInset * 2

    /// The panel's outer width in clipboard mode versus every other mode —
    /// the one place that decision is made, so the shell's frame and the
    /// resize animation can never disagree about which width applies.
    static func resolvedPanelWidth(isClipboardMode: Bool) -> CGFloat {
        isClipboardMode ? clipboardPanelWidth : panelWidth
    }

    /// How far the board's solid "well" insets from the panel's glass edge
    /// on its leading, trailing, and bottom sides — the same 7 pt as a
    /// result row's own padding, so the well reads as a scaled-up row.
    static let clipboardWellInset: CGFloat = resultPadding

    /// The well's 1 pt inside stroke, drawn in `.primary` so it adapts to
    /// both color schemes without a second hand-picked color.
    static let clipboardWellStrokeOpacity: Double = 0.12

    /// The well's corner radius: concentric with the panel's own
    /// `cornerRadius`, tightened by the inset that separates the two edges.
    static let clipboardWellCornerRadius: CGFloat = cornerRadius - clipboardWellInset

    /// The board's footer — entry count plus the Paste, Preview, and
    /// Actions chips. Clipboard mode adds it (and its divider) to the panel
    /// height, so the seventh row is never clipped behind the footer.
    static let clipboardFooterHeight: CGFloat = 32

    /// The clipboard board's panel height: the search row plus the solid
    /// well below it (filter bar, `maximumVisibleResults` full rows with
    /// their padding, the divider above the footer, and the footer itself),
    /// plus the well's own bottom inset outside that content.
    static var clipboardPanelHeight: CGFloat {
        searchHeight
            + filterBarHeight
            + resultPadding * 2
            + CGFloat(maximumVisibleResults) * resultRowHeight
            + 1
            + clipboardFooterHeight
            + clipboardWellInset
    }

    static var expandedPanelHeight: CGFloat {
        searchHeight
            + 1
            + filterBarHeight
            + resultPadding * 2
            + CGFloat(maximumVisibleResults) * resultRowHeight
    }

    static func panelHeight(hasQuery: Bool, isClipboardMode: Bool = false) -> CGFloat {
        guard hasQuery else { return searchHeight }
        return isClipboardMode ? clipboardPanelHeight : expandedPanelHeight
    }

    // MARK: - Content showcase (golden-state polish, #28)

    static let resultRowCornerRadius: CGFloat = 12
    static let standardIconSize: CGFloat = 38
    static let topHitIconSize: CGFloat = 46
    static let searchIconSize: CGFloat = 22
    static let clearButtonSize: CGFloat = 18

    /// Symbol-row icon tiles (calculator, settings, web, assistant) sit on a
    /// continuous-curve tile whose radius derives from the row radius minus
    /// how far the icon insets from the tile edge, so corners stay
    /// concentric — never a literal at the call site.
    static let iconTileInset: CGFloat = 3
    static var iconTileCornerRadius: CGFloat {
        resultRowCornerRadius - iconTileInset
    }

    static let iconTileTintOpacity: Double = 0.14

    /// Quiet, decorative fills that aren't text. Text hierarchy stays on
    /// SwiftUI's semantic `.secondary`/`.tertiary` styles instead of a
    /// parallel opacity scale — those already strengthen under Increase
    /// Contrast, which a hand-picked opacity number never would.
    static let badgeFillOpacity: Double = 0.07
    static let topHitWashOpacity: Double = 0.045
    /// A footer chip whose action does not apply to the selection stays in
    /// place at this opacity rather than disappearing (#57 board).
    static let footerChipDisabledOpacity: Double = 0.4

    enum Typography {
        static let rowTitle = Font.system(size: 15, weight: .medium)
        static let topHitTitle = Font.system(size: 19, weight: .semibold)
        static let rowSubtitle = Font.system(size: 11.5, weight: .medium)
        /// The assistant row's answered state — one size up from
        /// `rowSubtitle` since it's the actual answer, not metadata about
        /// it. Its running/failed states reuse `rowSubtitle` directly.
        static let assistantAnswer = Font.system(size: 12.5, weight: .regular)
        static let badge = Font.system(size: 8.5, weight: .bold)
        static let chip = Font.system(size: 11.5, weight: .semibold)
        static let keyChip = Font.system(size: 11, weight: .semibold)
        static let emptyState = Font.system(size: 13.5, weight: .medium)
        /// The inspector's file or image name under its preview — one size
        /// for every kind, so switching rows never re-scales the heading.
        static let inspectorTitle = Font.system(size: 15, weight: .semibold)
        static let inspectorSectionLabel = Font.system(size: 11.5, weight: .semibold)
        static let inspectorRow = Font.system(size: 12)
        /// Point size only — `FloodlightTextField` sets this on an `NSFont`
        /// directly, so there's no shared SwiftUI `Font` value to hand it.
        static let inputSize: CGFloat = 24
    }

    /// The tint for rows whose icon is an SF Symbol on a tile rather than a
    /// real file/app icon — Calculator, System Settings, Web, and the
    /// AI-assistant rows #27 adds. File/folder/app rows show their own
    /// system-provided icon and carry no tile tint.
    static func iconTint(for kind: SearchItemKind) -> Color {
        switch kind {
        case .assistant: .purple
        case .calculator: .orange
        case .clipboard: .teal
        case .systemSetting: .gray
        case .web: .blue
        case .application, .file, .folder: .accentColor
        }
    }

    // MARK: - Liquid Glass shell (#1)

    /// The fallback-path stroke opacity Increase Contrast raises chips and
    /// the selection lozenge to — the one accessibility number #1 needs
    /// that #28 didn't. Glass chips/selection reuse #28's existing
    /// `resultRowCornerRadius`/`Capsule()` shapes directly; nothing about
    /// this spec's geometry is new, only the material is.
    static let increasedContrastStrokeOpacity: Double = 0.45
}

extension SearchItemIconTint {
    /// The one place an engine's tint name becomes a color, so the result
    /// row's icon tile and the field's mode token can never drift apart.
    var color: Color {
        switch self {
        case .blue: .blue
        case .cyan: .cyan
        case .gray: .gray
        case .orange: .orange
        case .primary: .primary
        case .purple: .purple
        case .red: .red
        }
    }
}
