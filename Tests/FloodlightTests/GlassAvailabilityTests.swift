import Testing
@testable import Floodlight

struct GlassAvailabilityTests {
    @Test func glassRendersOnlyWhenSupportedAndTransparencyIsNotReduced() {
        #expect(GlassAvailability.rendersGlass(isSupported: true, reduceTransparency: false))
    }

    @Test func reduceTransparencySuppressesGlassEvenWhenSupported() {
        #expect(!(GlassAvailability.rendersGlass(isSupported: true, reduceTransparency: true)))
    }

    @Test func unsupportedOSNeverRendersGlassRegardlessOfTransparencySetting() {
        #expect(!(GlassAvailability.rendersGlass(isSupported: false, reduceTransparency: false)))
        #expect(!(GlassAvailability.rendersGlass(isSupported: false, reduceTransparency: true)))
    }
}
