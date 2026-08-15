import FloodlightEngine
import XCTest
@testable import Floodlight

final class FloodlightMetricsTests: XCTestCase {
    func testExpandedPanelReservesFilterBarWithoutReducingVisibleRows() {
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

    func testIconTileCornerRadiusIsConcentricWithTheRowRadius() {
        XCTAssertEqual(
            FloodlightMetrics.iconTileCornerRadius,
            FloodlightMetrics.resultRowCornerRadius - FloodlightMetrics.iconTileInset
        )
        XCTAssertEqual(FloodlightMetrics.iconTileCornerRadius, 9)
    }

    func testIconTintAssignsEachSymbolRowItsOwnColorAndFileishRowsShareTheAccent() {
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .calculator), .orange)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .systemSetting), .gray)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .web), .blue)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .assistant), .purple)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .application), .accentColor)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .file), .accentColor)
        XCTAssertEqual(FloodlightMetrics.iconTint(for: .folder), .accentColor)
    }
}
