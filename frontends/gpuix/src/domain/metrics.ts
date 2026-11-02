/**
 * The Swift `FloodlightMetrics`, in points. Components read every size from
 * here, never a literal, so the GPUIX panel and the Swift panel stay the same
 * shape and the native layer resizes the window to the size React lays out.
 */

export const PANEL_WIDTH = 680;
export const SEARCH_HEIGHT = 60;
export const FILTER_BAR_HEIGHT = 40;
export const CORNER_RADIUS = SEARCH_HEIGHT / 2;
export const RESULT_ROW_HEIGHT = 58;
export const RESULT_PADDING = 7;
export const MAX_VISIBLE_RESULTS = 7;
export const RESULT_ROW_CORNER_RADIUS = 12;
export const ICON_SIZE = 38;
export const TOP_HIT_ICON_SIZE = 46;
export const SEARCH_ICON_SIZE = 22;
export const ICON_TILE_INSET = 3;
export const NOTICE_HEIGHT = 32;

export const BOARD_LIST_WIDTH = 360;
export const BOARD_INSPECTOR_WIDTH = 465;
export const BOARD_WELL_INSET = RESULT_PADDING;
export const BOARD_WELL_CORNER_RADIUS = CORNER_RADIUS - BOARD_WELL_INSET;
export const BOARD_FOOTER_HEIGHT = 32;
export const BOARD_WIDTH = BOARD_LIST_WIDTH + 1 + BOARD_INSPECTOR_WIDTH + BOARD_WELL_INSET * 2;
export const BOARD_HEIGHT =
  SEARCH_HEIGHT +
  FILTER_BAR_HEIGHT +
  RESULT_PADDING * 2 +
  MAX_VISIBLE_RESULTS * RESULT_ROW_HEIGHT +
  1 +
  BOARD_FOOTER_HEIGHT +
  BOARD_WELL_INSET;

export const EXPANDED_HEIGHT =
  SEARCH_HEIGHT + 1 + FILTER_BAR_HEIGHT + RESULT_PADDING * 2 + MAX_VISIBLE_RESULTS * RESULT_ROW_HEIGHT;

export const GUIDANCE_WIDTH = 360;
export const GUIDANCE_HEIGHT = 168;

export const FONT_INPUT = 24;
export const FONT_ROW_TITLE = 15;
export const FONT_TOP_HIT_TITLE = 19;
export const FONT_ROW_SUBTITLE = 11.5;
export const FONT_BADGE = 8.5;
export const FONT_CHIP = 11.5;
export const FONT_KEY_CHIP = 11;
export const FONT_EMPTY = 13.5;
export const FONT_INSPECTOR_TITLE = 15;
export const FONT_INSPECTOR_LABEL = 11.5;
export const FONT_INSPECTOR_ROW = 12;

export class PanelSize {
  constructor(
    readonly width: number,
    readonly height: number,
  ) {}
}

/**
 * Two heights, as in Swift: the bare search bar while the field is empty,
 * the full list once there is a query. A list that grows row by row would
 * resize the window on every keystroke, which is the stale-frame case.
 */
export function panelSize(hasQuery: boolean, board: boolean, notice: boolean): PanelSize {
  if (board) return new PanelSize(BOARD_WIDTH, BOARD_HEIGHT);
  const base = hasQuery ? EXPANDED_HEIGHT : SEARCH_HEIGHT;
  return new PanelSize(PANEL_WIDTH, base + (notice ? NOTICE_HEIGHT : 0));
}
