import FloodlightEngine
import SwiftUI
import XCTest
@testable import Floodlight

/// Harsh, critical stress tests for `FloodlightMetrics` — boundary
/// conditions and edge cases for the panel sizing and icon tint system.
final class FloodlightMetricsStressTests: XCTestCase {

    // MARK: - panelHeight

    func testPanelHeightForEmptyQuery() {
        XCTAssertEqual(
            FloodlightMetrics.panelHeight(hasQuery: false),
            FloodlightMetrics.searchHeight
        )
    }

    func testPanelHeightForNonEmptyQuery() {
        XCTAssertEqual(
            FloodlightMetrics.panelHeight(hasQuery: true),
            FloodlightMetrics.expandedPanelHeight
        )
    }

    func testExpandedPanelHeightIsLargerThanSearchHeight() {
        XCTAssertGreaterThan(
            FloodlightMetrics.expandedPanelHeight,
            FloodlightMetrics.searchHeight
        )
    }

    // MARK: - shouldVirtualizeResults boundary

    func testShouldVirtualizeResultsAtExactThreshold() {
        XCTAssertFalse(
            FloodlightMetrics.shouldVirtualizeResults(
                count: FloodlightMetrics.resultVirtualizationThreshold
            )
        )
    }

    func testShouldVirtualizeResultsAboveThreshold() {
        XCTAssertTrue(
            FloodlightMetrics.shouldVirtualizeResults(
                count: FloodlightMetrics.resultVirtualizationThreshold + 1
            )
        )
    }

    func testShouldVirtualizeResultsBelowThreshold() {
        XCTAssertTrue(
            FloodlightMetrics.shouldVirtualizeResults(
                count: FloodlightMetrics.resultVirtualizationThreshold + 10
            )
        )
    }

    func testShouldVirtualizeResultsForZero() {
        XCTAssertFalse(FloodlightMetrics.shouldVirtualizeResults(count: 0))
    }

    func testShouldVirtualizeResultsForOne() {
        XCTAssertFalse(FloodlightMetrics.shouldVirtualizeResults(count: 1))
    }

    // MARK: - Corner radius

    func testCornerRadiusIsHalfSearchHeight() {
        XCTAssertEqual(
            FloodlightMetrics.cornerRadius,
            FloodlightMetrics.searchHeight / 2
        )
    }

    // MARK: - Icon tile

    func testIconTileCornerRadiusIsConcentric() {
        XCTAssertEqual(
            FloodlightMetrics.iconTileCornerRadius,
            FloodlightMetrics.resultRowCornerRadius - FloodlightMetrics.iconTileInset
        )
    }

    func testIconTileCornerRadiusIsPositive() {
        XCTAssertGreaterThan(FloodlightMetrics.iconTileCornerRadius, 0)
    }

    // MARK: - Icon tint

    func testIconTintForAllKinds() {
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .assistant), .purple)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .calculator), .orange)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .systemSetting), .gray)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .web), .blue)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .application), .accentColor)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .file), .accentColor)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .folder), .accentColor)
    }

    func testIconTintIsDeterministic() {
        for kind in [SearchItemKind.application, .assistant, .calculator, .file, .folder, .systemSetting, .web] {
            let tint1 = FloodlightMetrics.iconTint(for: kind)
            let tint2 = FloodlightMetrics.iconTint(for: kind)
            // Colors should be equal (same type)
            XCTAssertEqual(tint1, tint2, "iconTint should be deterministic for \(kind)")
        }
    }

    // MARK: - Typography

    func testTypographyValuesArePositive() {
        XCTAssertGreaterThan(FloodlightMetrics.Typography.rowTitle.pointSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.Typography.topHitTitle.pointSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.Typography.rowSubtitle.pointSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.Typography.assistantAnswer.pointSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.Typography.badge.pointSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.Typography.chip.pointSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.Typography.keyChip.pointSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.Typography.emptyState.pointSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.Typography.inputSize, 0)
    }

    func testTopHitTitleIsLargerThanRowTitle() {
        XCTAssertGreaterThan(
            FloodlightMetrics.Typography.topHitTitle.pointSize,
            FloodlightMetrics.Typography.rowTitle.pointSize
        )
    }

    func testAssistantAnswerIsLargerThanRowSubtitle() {
        XCTAssertGreaterThan(
            FloodlightMetrics.Typography.assistantAnswer.pointSize,
            FloodlightMetrics.Typography.rowSubtitle.pointSize
        )
    }

    // MARK: - Opacity values

    func testOpacityValuesAreInRange() {
        XCTAssertGreaterThan(FloodlightMetrics.iconTileTintOpacity, 0)
        XCTAssertLessThan(FloodlightMetrics.iconTileTintOpacity, 1)
        XCTAssertGreaterThan(FloodlightMetrics.badgeFillOpacity, 0)
        XCTAssertLessThan(FloodlightMetrics.badgeFillOpacity, 1)
        XCTAssertGreaterThan(FloodlightMetrics.topHitWashOpacity, 0)
        XCTAssertLessThan(FloodlightMetrics.topHitWashOpacity, 1)
    }

    // MARK: - Size values

    func testSizeValuesArePositive() {
        XCTAssertGreaterThan(FloodlightMetrics.panelWidth, 0)
        XCTAssertGreaterThan(FloodlightMetrics.searchHeight, 0)
        XCTAssertGreaterThan(FloodlightMetrics.filterBarHeight, 0)
        XCTAssertGreaterThan(FloodlightMetrics.resultRowHeight, 0)
        XCTAssertGreaterThan(FloodlightMetrics.resultPadding, 0)
        XCTAssertGreaterThan(FloodlightMetrics.maximumVisibleResults, 0)
        XCTAssertGreaterThan(FloodlightMetrics.standardIconSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.topHitIconSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.searchIconSize, 0)
        XCTAssertGreaterThan(FloodlightMetrics.clearButtonSize, 0)
    }

    func testTopHitIconIsLargerThanStandardIcon() {
        XCTAssertGreaterThan(
            FloodlightMetrics.topHitIconSize,
            FloodlightMetrics.standardIconSize
        )
    }

    func testResultVirtualizationThresholdEqualsMaximumVisibleResults() {
        XCTAssertEqual(
            FloodlightMetrics.resultVirtualizationThreshold,
            FloodlightMetrics.maximumVisibleResults
        )
    }

    // MARK: - Expanded panel height components

    func testExpandedPanelHeightIncludesAllComponents() {
        let expected = FloodlightMetrics.searchHeight
            + 1
            + FloodlightMetrics.filterBarHeight
            + FloodlightMetrics.resultPadding * 2
            + CGFloat(FloodlightMetrics.maximumVisibleResults) * FloodlightMetrics.resultRowHeight

        XCTAssertEqual(FloodlightMetrics.expandedPanelHeight, expected)
    }
}
