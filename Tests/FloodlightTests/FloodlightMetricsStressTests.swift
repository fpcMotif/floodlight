import FloodlightEngine
import SwiftUI
import Testing
@testable import Floodlight

struct FloodlightMetricsStressTests {
    // MARK: - panelHeight

    @Test func panelHeightForEmptyQueryIsSearchHeight() {
        #expect(FloodlightMetrics.panelHeight(hasQuery: false) == FloodlightMetrics.searchHeight)
    }

    @Test func panelHeightForNonEmptyQueryIsExpandedHeight() {
        #expect(FloodlightMetrics.panelHeight(hasQuery: true) == FloodlightMetrics
            .expandedPanelHeight)
    }

    @Test func expandedPanelHeightIsGreaterThanSearchHeight() {
        #expect(FloodlightMetrics.expandedPanelHeight > FloodlightMetrics.searchHeight)
    }

    // MARK: - cornerRadius

    @Test func cornerRadiusIsHalfSearchHeight() {
        #expect(FloodlightMetrics.cornerRadius == FloodlightMetrics.searchHeight / 2)
    }

    // MARK: - iconTileCornerRadius

    @Test func iconTileCornerRadiusIsConcentricWithRowRadius() {
        #expect(FloodlightMetrics.iconTileCornerRadius == FloodlightMetrics
            .resultRowCornerRadius - FloodlightMetrics.iconTileInset)
        #expect(FloodlightMetrics.iconTileCornerRadius < FloodlightMetrics.resultRowCornerRadius)
        #expect(FloodlightMetrics.iconTileCornerRadius > 0)
    }

    // MARK: - iconTint

    @Test func iconTintForAllKinds() {
        #expect(FloodlightMetrics.iconTint(for: .assistant) == .purple)
        #expect(FloodlightMetrics.iconTint(for: .calculator) == .orange)
        #expect(FloodlightMetrics.iconTint(for: .systemSetting) == .gray)
        #expect(FloodlightMetrics.iconTint(for: .web) == .blue)
        #expect(FloodlightMetrics.iconTint(for: .application) == .accentColor)
        #expect(FloodlightMetrics.iconTint(for: .file) == .accentColor)
        #expect(FloodlightMetrics.iconTint(for: .folder) == .accentColor)
    }

    // MARK: - opacity values

    @Test func iconTileTintOpacityInRange() {
        #expect(FloodlightMetrics.iconTileTintOpacity > 0)
        #expect(FloodlightMetrics.iconTileTintOpacity <= 1)
    }

    @Test func badgeFillOpacityInRange() {
        #expect(FloodlightMetrics.badgeFillOpacity > 0)
        #expect(FloodlightMetrics.badgeFillOpacity <= 1)
    }

    @Test func topHitWashOpacityInRange() {
        #expect(FloodlightMetrics.topHitWashOpacity > 0)
        #expect(FloodlightMetrics.topHitWashOpacity <= 1)
    }

    // MARK: - size values positive

    @Test func sizeValuesArePositive() {
        #expect(FloodlightMetrics.panelWidth > 0)
        #expect(FloodlightMetrics.searchHeight > 0)
        #expect(FloodlightMetrics.filterBarHeight > 0)
        #expect(FloodlightMetrics.resultRowHeight > 0)
        #expect(FloodlightMetrics.resultPadding > 0)
        #expect(FloodlightMetrics.maximumVisibleResults > 0)
        #expect(FloodlightMetrics.resultRowCornerRadius > 0)
        #expect(FloodlightMetrics.standardIconSize > 0)
        #expect(FloodlightMetrics.topHitIconSize > 0)
        #expect(FloodlightMetrics.searchIconSize > 0)
        #expect(FloodlightMetrics.clearButtonSize > 0)
        #expect(FloodlightMetrics.iconTileInset > 0)
        #expect(FloodlightMetrics.Typography.inputSize > 0)
    }

    // MARK: - topHitIcon > standardIcon

    @Test func topHitIconLargerThanStandardIcon() {
        #expect(FloodlightMetrics.topHitIconSize > FloodlightMetrics.standardIconSize)
    }

    // MARK: - expanded panel height components

    @Test func expandedPanelHeightComposesFromAllComponents() {
        #expect(FloodlightMetrics.expandedPanelHeight == FloodlightMetrics.searchHeight
            + 1
            + FloodlightMetrics.filterBarHeight
            + FloodlightMetrics.resultPadding * 2
            + CGFloat(FloodlightMetrics.maximumVisibleResults)
            * FloodlightMetrics.resultRowHeight)
    }

    // MARK: - Typography values exist (Font values, not CGFloat)

    @Test func typographyValuesExist() {
        #expect(FloodlightMetrics.Typography.rowTitle as Any? != nil)
        #expect(FloodlightMetrics.Typography.topHitTitle as Any? != nil)
        #expect(FloodlightMetrics.Typography.rowSubtitle as Any? != nil)
        #expect(FloodlightMetrics.Typography.assistantAnswer as Any? != nil)
        #expect(FloodlightMetrics.Typography.badge as Any? != nil)
        #expect(FloodlightMetrics.Typography.chip as Any? != nil)
        #expect(FloodlightMetrics.Typography.keyChip as Any? != nil)
        #expect(FloodlightMetrics.Typography.emptyState as Any? != nil)
    }

    @Test func typographyInputSizeIsCGFloat() {
        // inputSize is the one Typography property that's a CGFloat, not a Font.
        #expect(FloodlightMetrics.Typography.inputSize == 24)
    }
}
