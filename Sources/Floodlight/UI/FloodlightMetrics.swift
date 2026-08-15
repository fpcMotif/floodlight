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

    static var expandedPanelHeight: CGFloat {
        searchHeight
            + 1
            + filterBarHeight
            + resultPadding * 2
            + CGFloat(maximumVisibleResults) * resultRowHeight
    }

    static func panelHeight(hasQuery: Bool) -> CGFloat {
        guard hasQuery else { return searchHeight }
        return expandedPanelHeight
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
