/** What a result row says beside its title: the kind badge and the subtitle. */
import { formatBytes, formatDay } from "./format";
import { KIND_APP, KIND_CALCULATOR, KIND_FILE, KIND_FOLDER, KIND_SETTING, KIND_WEB, Row } from "./row";

/** `APP`, `FOLDER`, `PDF`: the file's extension where it has one. */
export function rowBadge(row: Row): string {
  if (row.kind === KIND_APP) return "APP";
  if (row.kind === KIND_FOLDER) return "FOLDER";
  if (row.kind === KIND_FILE) return row.ext.length > 0 ? row.ext.toUpperCase() : "FILE";
  if (row.kind === KIND_WEB) return "WEB";
  if (row.kind === KIND_CALCULATOR) return "CALC";
  if (row.kind === KIND_SETTING) return "SETTING";
  return "";
}

/** `~/Documents · 12 KB · Today`: where it is, how big, when it changed. */
export function rowSubtitle(row: Row, nowSeconds: number): string {
  const parts: string[] = [];
  if (row.detail.length > 0) parts.push(row.detail);
  if (row.size >= 0) parts.push(formatBytes(row.size));
  const day = formatDay(row.modified, nowSeconds);
  if (day.length > 0) parts.push(day);
  return parts.join(" · ");
}

/**
 * The first row of a window of `visible` rows that keeps `selected` in view,
 * moving as little as possible from `top`.
 */
export function windowTop(top: number, selected: number, visible: number, count: number): number {
  let next = top;
  if (selected < next) next = selected;
  if (selected >= next + visible) next = selected - visible + 1;
  return Math.max(0, Math.min(next, Math.max(0, count - visible)));
}
