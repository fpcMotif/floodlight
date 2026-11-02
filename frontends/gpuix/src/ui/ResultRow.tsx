/** One result: icon, title with its matched letters, kind badge and subtitle. */
import {
  FONT_BADGE,
  FONT_ROW_SUBTITLE,
  FONT_ROW_TITLE,
  FONT_TOP_HIT_TITLE,
  ICON_SIZE,
  ICON_TILE_INSET,
  RESULT_ROW_CORNER_RADIUS,
  RESULT_ROW_HEIGHT,
  TOP_HIT_ICON_SIZE,
} from "../domain/metrics";
import { KIND_CALCULATOR, KIND_SETTING, KIND_WEB, Row } from "../domain/row";
import { rowBadge, rowSubtitle } from "../domain/row-text";
import { useServices } from "./context";
import { FONT, type Theme } from "./theme";

/** Rows with no Finder icon get a glyph on a tinted tile. */
function glyphFor(row: Row): string {
  if (row.kind === KIND_WEB) return "🌐";
  if (row.kind === KIND_CALCULATOR) return "=";
  if (row.kind === KIND_SETTING) return "⚙";
  return "•";
}

/** Consecutive marks as [start, end) ranges, the shape `highlight` takes. */
function ranges(marks: number[]): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  for (const m of marks) {
    const last = out[out.length - 1];
    if (last !== undefined && last[1] === m) last[1] = m + 1;
    else out.push([m, m + 1]);
  }
  return out;
}

export function ResultRow(props: {
  row: Row;
  index: number;
  selected: boolean;
  topHit: boolean;
  now: number;
  theme: Theme;
}) {
  const { controller, icons } = useServices();
  const { row, theme, topHit } = props;
  const size = topHit ? TOP_HIT_ICON_SIZE : ICON_SIZE;
  const icon = icons.forRow(row);
  const subtitle = rowSubtitle(row, props.now);
  return (
    <div
      onClick={() => controller.openRow(props.index)}
      style={{
        display: "flex",
        flexDirection: "row",
        alignItems: "center",
        gap: 12,
        height: RESULT_ROW_HEIGHT,
        flexShrink: 0,
        paddingLeft: 10,
        paddingRight: 12,
        borderRadius: RESULT_ROW_CORNER_RADIUS,
        backgroundColor: props.selected ? theme.selection : "#00000000",
      }}
    >
      {icon.length > 0 ? (
        <img src={icon} objectFit="contain" style={{ width: size, height: size }} />
      ) : (
        <div
          style={{
            width: size,
            height: size,
            borderRadius: RESULT_ROW_CORNER_RADIUS - ICON_TILE_INSET,
            backgroundColor: theme.badgeFill,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <text style={{ fontSize: size / 2, fontFamily: FONT, color: theme.secondary }}>{glyphFor(row)}</text>
        </div>
      )}
      <div style={{ display: "flex", flexDirection: "column", flexGrow: 1, minWidth: 0, gap: 2 }}>
        <div style={{ display: "flex", flexDirection: "row", alignItems: "center", gap: 6 }}>
          <div highlight={{ ranges: ranges(row.marks), color: theme.highlight }} style={{ flexShrink: 1, minWidth: 0 }}>
            <text
              style={{
                fontSize: topHit ? FONT_TOP_HIT_TITLE : FONT_ROW_TITLE,
                fontFamily: FONT,
                fontWeight: topHit ? 600 : 500,
                color: theme.primary,
                whiteSpace: "nowrap",
                textOverflow: "ellipsis",
              }}
            >
              {row.title}
            </text>
          </div>
          <div style={{ paddingLeft: 5, paddingRight: 5, borderRadius: 4, backgroundColor: theme.badgeFill }}>
            <text style={{ fontSize: FONT_BADGE, fontFamily: FONT, fontWeight: 700, color: theme.secondary }}>
              {rowBadge(row)}
            </text>
          </div>
        </div>
        {subtitle.length > 0 ? (
          <text
            style={{
              fontSize: FONT_ROW_SUBTITLE,
              fontFamily: FONT,
              fontWeight: 500,
              color: theme.secondary,
              whiteSpace: "nowrap",
              textOverflow: "ellipsis",
            }}
          >
            {subtitle}
          </text>
        ) : null}
      </div>
    </div>
  );
}
