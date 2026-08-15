import FloodlightEngine
import SwiftUI
import XCTest
@testable import Floodlight

final class FloodlightMetricsStressTests: XCTestCase {
    // MARK: - panelHeight

    func testPanelHeightForEmptyQueryIsSearchHeight() {
        XCTAssertEqual(
            FloodlightMetrics.panelHeight(hasQuery: false),
            FloodlightMetrics.searchHeight
        )
    }

    func testPanelHeightForNonEmptyQueryIsExpandedHeight() {
        XCTAssertEqual(
            FloodlightMetrics.panelHeight(hasQuery: true),
            FloodlightMetrics.expandedPanelHeight
        )
    }

    func testExpandedPanelHeightIsGreaterThanSearchHeight() {
        XCTAssertGreaterThan(FloodlightMetrics.expandedPanelHeight, FloodlightMetrics.searchHeight)
    }

    // MARK: - cornerRadius

    func testCornerRadiusIsHalfSearchHeight() {
        XCTAssertEqual(FloodlightMetrics.cornerRadius, FloodlightMetrics.searchHeight / 2)
    }

    // MARK: - iconTileCornerRadius

    func testIconTileCornerRadiusIsConcentricWithRowRadius() {
        XCTAssertEqual(
            FloodlightMetrics.iconTileCornerRadius,
            FloodlightMetrics.resultRowCornerRadius - FloodlightMetrics.iconTileInset
        )
        XCTAssertLessThan(
            FloodlightMetrics.iconTileCornerRadius,
            FloodlightMetrics.resultRowCornerRadius
        )
        XCTAssertGreaterThan(FloodlightMetrics.iconTileCornerRadius, 0)
    }

    // MARK: - iconTint

    func testIconTintForAllKinds() {
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .assistant), .purple)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .calculator), .orange)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .systemSetting), .gray)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .web), .blue)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .application), .accentColor)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .file), .accentColor)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .folder), .accentColor)
    }

    // MARK: - opacity values

    func testIconTileTintOpacityInRange() {
        XCTAssertGreaterThan(FloodlightMetrics.iconTileTintOpacity, 0)
        XCTAssertLessThanOrEqual(FloodlightMetrics.iconTileTintOpacity, 1)
    }

    func testBadgeFillOpacityInRange() {
        XCTAssertGreaterThan(FloodlightMetrics.badgeFillOpacity, 0)
        XCTAssertLessThanOrEqual(FloodlightMetrics.badgeFillOpacity, 1)
    }

    func testTopHitWashOpacityInRange() {
        XCTAssertGreaterThan(FloodlightMetrics.topHitWashOpacity, 0)
        XCTAssertLessThanOrEqual(FloodlightMetrics.topHitWashOpacity, 1)
    }

    // MARK: - size values positive

    func testSizeValuesArePositive() {
        XCTAssertGreaterThan(FloodlightMetrics.panelWidth, 0)
        XCTAssertGreaterThan(FloodlightMetrics.searchHeight, 0)
        XCTAssertGreaterThan(FloodlightMetrics.filterBarHeight, 0)
        XCTAssertGreaterThan(FloodlightMetrics.resultRowHeight, 0)
        XCTAssertGreaterThan(FloodlightMetrics.resultPadding, 0)
        XCTAssertGreaterThan(FloodlightMetrics.maximumVisibleResults, 0)
        XCTAssertGreaterThan(FloodlightMetrics.resultRowCornerRadius, 0)
        XCTAssertGreaterThan(FloodlightMetrics.standardIconSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.topHitIconSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.searchIconSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.clearButtonSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.iconTileInset, 0)
        XCTAssertGreaterThan(FloodlightMetrics.Typography.inputSize, 0)
    }

    // MARK: - topHitIcon > standardIcon

    func testTopHitIconLargerThanStandardIcon() {
        XCTAssertGreaterThan(
            FloodlightMetrics.topHitIconSize,
            FloodlightMetrics.standardIconSize
        )
    }

    // MARK: - expanded panel height components

    func testExpandedPanelHeightComposesFromAllComponents() {
        XCTAssertEqual(
            FloodlightMetrics.expandedPanelHeight,
            FloodlightMetrics.searchHeight
                + 1
                + FloodlightMetrics.filterBarHeight
                + FloodlightMetrics.resultPadding * 2
                + CGFloat(FloodlightMetrics.maximumVisibleResults)
                * FloodlightMetrics.resultRowHeight
        )
    }

    // MARK: - Typography values exist (Font values, not CGFloat)

    func testTypographyValuesExist() {
        XCTAssertNotNil(FloodlightMetrics.Typography.rowTitle as Any?)
        XCTAssertNotNil(FloodlightMetrics.Typography.topHitTitle as Any?)
        XCTAssertNotNil(FloodlightMetrics.Typography.rowSubtitle as Any?)
        XCTAssertNotNil(FloodlightMetrics.Typography.assistantAnswer as Any?)
        XCTAssertNotNil(FloodlightMetrics.Typography.badge as Any?)
        XCTAssertNotNil(FloodlightMetrics.Typography.chip as Any?)
        XCTAssertNotNil(FloodlightMetrics.Typography.keyChip as Any?)
        XCTAssertNotNil(FloodlightMetrics.Typography.emptyState as Any?)
    }

    func testTypographyInputSizeIsCGFloat() {
        // inputSize is the one Typography property that's a CGFloat, not a Font.
        XCTAssertEqual(FloodlightMetrics.Typography.inputSize, 24)
    }
}
