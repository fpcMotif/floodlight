package main

// The Swift app's FloodlightMetrics, so the panel and the board come out the
// same size as the Swift ones. Views read these names, never literals.
const (
	panelWidth         = 680
	searchHeight       = 60
	filterBarHeight    = 40
	resultRowHeight    = 58
	resultPadding      = 7
	maxVisibleResults  = 7
	panelCornerRadius  = searchHeight / 2
	rowCornerRadius    = 12
	standardIconSize   = 38
	topHitIconSize     = 46
	searchIconSize     = 22
	inputFontSize      = 24
	rowTitleSize       = 15
	topHitTitleSize    = 19
	rowSubtitleSize    = 11.5
	badgeSize          = 8.5
	chipSize           = 11.5
	keyChipSize        = 11
	iconPixels         = 64 // icons are drawn from 64 px PNGs: 38 pt at 1.5×, 46 pt sharp enough
	panelMaxHeight     = searchHeight + filterBarHeight + maxVisibleResults*resultRowHeight + 2*resultPadding
	boardWidth         = 840
	boardHeight        = 560
	boardListWidth     = 360
	boardInspectorW    = 465
	boardFooterHeight  = 32
	boardSearchHeight  = 52
	inspectorTitleSize = 15
	inspectorLabelSize = 11.5
	inspectorRowSize   = 12
	guidanceWidth      = 380
	guidanceHeight     = 110
)

// panelHeight is the panel's height for n visible rows: the bare search bar
// when there are none, then the bar, the chips and up to seven rows.
func panelHeight(n int) int {
	if n == 0 {
		return searchHeight
	}
	return searchHeight + filterBarHeight + min(n, maxVisibleResults)*resultRowHeight + 2*resultPadding
}
