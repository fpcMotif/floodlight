import XCTest
@testable import Floodlight

final class FloodlightMetricsTests: XCTestCase {
    func testVirtualizesResultsBeyondVisibleCapacity() {
        XCTAssertFalse(
            FloodlightMetrics.shouldVirtualizeResults(
                count: FloodlightMetrics.resultVirtualizationThreshold
            )
        )
        XCTAssertTrue(
            FloodlightMetrics.shouldVirtualizeResults(
                count: FloodlightMetrics.resultVirtualizationThreshold + 1
            )
        )
    }

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
}
