import CoreGraphics
import FloodlightEngine
import Testing
@testable import Floodlight

struct FloodlightMetricsTests {
    @Test func expandedPanelReservesFilterBarWithoutReducingVisibleRows() {
        #expect(FloodlightMetrics.expandedPanelHeight == FloodlightMetrics.searchHeight
            + 1
            + FloodlightMetrics.filterBarHeight
            + FloodlightMetrics.resultPadding * 2
            + CGFloat(FloodlightMetrics.maximumVisibleResults)
            * FloodlightMetrics.resultRowHeight)
    }

    @Test func iconTileCornerRadiusIsConcentricWithTheRowRadius() {
        #expect(FloodlightMetrics.iconTileCornerRadius == FloodlightMetrics
            .resultRowCornerRadius - FloodlightMetrics.iconTileInset)
        #expect(FloodlightMetrics.iconTileCornerRadius == 9)
    }

    @Test func iconTintAssignsEachSymbolRowItsOwnColorAndFileishRowsShareTheAccent() {
        #expect(FloodlightMetrics.iconTint(for: .calculator) == .orange)
        #expect(FloodlightMetrics.iconTint(for: .systemSetting) == .gray)
        #expect(FloodlightMetrics.iconTint(for: .web) == .blue)
        #expect(FloodlightMetrics.iconTint(for: .assistant) == .purple)
        #expect(FloodlightMetrics.iconTint(for: .application) == .accentColor)
        #expect(FloodlightMetrics.iconTint(for: .file) == .accentColor)
        #expect(FloodlightMetrics.iconTint(for: .folder) == .accentColor)
    }
}
