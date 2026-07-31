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
}
