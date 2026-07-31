import CoreGraphics

enum FloodlightMetrics {
    static let panelWidth: CGFloat = 680
    static let searchHeight: CGFloat = 60
    static let filterBarHeight: CGFloat = 40
    static let cornerRadius: CGFloat = searchHeight / 2
    static let resultRowHeight: CGFloat = 58
    static let resultPadding: CGFloat = 7
    static let maximumVisibleResults = 7
    static let resultVirtualizationThreshold = maximumVisibleResults

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

    static func shouldVirtualizeResults(count: Int) -> Bool {
        count > resultVirtualizationThreshold
    }
}
