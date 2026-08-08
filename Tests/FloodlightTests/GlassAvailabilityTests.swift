import XCTest
@testable import Floodlight

final class GlassAvailabilityTests: XCTestCase {
    func testGlassRendersOnlyWhenSupportedAndTransparencyIsNotReduced() {
        XCTAssertTrue(
            GlassAvailability.rendersGlass(isSupported: true, reduceTransparency: false)
        )
    }

    func testReduceTransparencySuppressesGlassEvenWhenSupported() {
        XCTAssertFalse(
            GlassAvailability.rendersGlass(isSupported: true, reduceTransparency: true)
        )
    }

    func testUnsupportedOSNeverRendersGlassRegardlessOfTransparencySetting() {
        XCTAssertFalse(
            GlassAvailability.rendersGlass(isSupported: false, reduceTransparency: false)
        )
        XCTAssertFalse(
            GlassAvailability.rendersGlass(isSupported: false, reduceTransparency: true)
        )
    }
}
