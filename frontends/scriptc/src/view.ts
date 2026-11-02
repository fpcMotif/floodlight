/**
 * Lays the search session out on the screen. Pure: session and status in,
 * cells out, so the self-test can check a frame without a terminal.
 *
 *    ❯ saf▏                                                   4 results
 *    All 4   Apps 1   Files 2   Folders 0
 *   ────────────────────────────────────────────────────────────────────
 *    ★ APP  Safari                                         /Applications
 *      DIR  safari-exports                     ~/Documents · Yesterday
 *      FILE Safari Bookmarks.html              ~/Desktop · 12 KB · Today
 *      WEB  Google                                           google.com
 *   ────────────────────────────────────────────────────────────────────
 *    ↑↓ ⏎ open ⌥⏎ reveal ^Y preview ⇥ web ⌥1-6 filter esc   412,331 files
 */
import { engineById } from "./engines";
import { FILTER_TITLES, visibleFilters } from "./filters";
import { formatBytes, formatDay, group } from "./format";
import { KIND_APP, KIND_CALCULATOR, KIND_FILE, KIND_FOLDER, KIND_SETTING, KIND_WEB, Row } from "./row";
import { isImageExtension } from "./filters";
import { MODE_WEB, SearchSession } from "./session";
import { Screen, STYLE_ACCENT, STYLE_BOLD, STYLE_DIM, STYLE_PLAIN, STYLE_SELECTED, textWidth } from "./screen";

export class Status {
  constructor(
    /** Entries in the file index; negative while the first build runs. */
    readonly fileCount: number,
    readonly building: boolean,
    /** The Full Disk Access notice, or "" when there is none. */
    readonly notice: string = "",
    /** Seconds since 1970, for "Today" in subtitles. */
    readonly now: number = 0,
  ) {}
}

const PROMPT = " ❯ ";
const HEADER_ROWS = 3;
const FOOTER_ROWS = 2;
const HELP = "↑↓ ⏎ open ⌥⏎ reveal ^Y preview ⇥ web ⌥1-6 filter ^B clipboard esc";

/** Rows available for results at a given screen height. */
export function listRows(screenRows: number, notice: boolean = false): number {
  return Math.max(1, screenRows - HEADER_ROWS - FOOTER_ROWS - (notice ? 1 : 0));
}

/** First visible result, keeping the selection on screen. */
export function scrollTop(selected: number, count: number, visible: number): number {
  if (count <= visible) return 0;
  const top = selected - visible + 1;
  return Math.max(0, Math.min(top, count - visible));
}

/** Keeps the tail of a path, which is the part that tells two apart. */
export function clipLeft(text: string, width: number): string {
  if (width <= 0) return "";
  if (textWidth(text) <= width) return text;
  const chars = Array.from(text);
  let out = "";
  let used = 1;
  for (let i = chars.length - 1; i >= 0; i--) {
    const w = textWidth(chars[i]);
    if (used + w > width) break;
    out = chars[i] + out;
    used += w;
  }
  return "…" + out;
}

export function rule(screen: Screen, row: number): void {
  screen.put(row, 0, "─".repeat(screen.cols), STYLE_DIM);
}

/** The kind badge: four cells, so titles line up. */
export function badge(row: Row): string {
  if (row.kind === KIND_APP) return "APP ";
  if (row.kind === KIND_FOLDER) return "DIR ";
  if (row.kind === KIND_WEB) return row.id === "direct-link" ? "LINK" : "WEB ";
  if (row.kind === KIND_CALCULATOR) return "CALC";
  if (row.kind === KIND_SETTING) return "SET ";
  if (row.kind === KIND_FILE && row.ext === "pdf") return "PDF ";
  if (row.kind === KIND_FILE && isImageExtension(row.ext)) return "IMG ";
  return "FILE";
}

/** Location, size and date: what tells two files with one name apart. */
export function subtitle(row: Row, now: number): string {
  let out = row.detail;
  if (row.size >= 0) out += " · " + formatBytes(row.size);
  if (row.modified > 0 && now > 0) out += " · " + formatDay(row.modified, now);
  return out;
}

function drawRow(screen: Screen, line: number, row: Row, selected: boolean, top: boolean, now: number): void {
  const base = selected ? STYLE_SELECTED : STYLE_PLAIN;
  if (selected) screen.fillRow(line, base);
  let col = screen.put(line, 0, top ? " ★ " : "   ", base | STYLE_ACCENT);
  col = screen.put(line, col, badge(row), base | STYLE_DIM);
  col = screen.put(line, col, " ", base);

  const detail = subtitle(row, now);
  // Detail takes the right side, but never more than half the row.
  const detailWidth = Math.min(textWidth(detail), Math.floor((screen.cols - col) / 2));
  const titleEnd = screen.cols - detailWidth - 2;
  let offset = 0;
  let mark = 0;
  for (const ch of Array.from(row.title)) {
    while (mark < row.marks.length && row.marks[mark] < offset) mark++;
    const hit = mark < row.marks.length && row.marks[mark] === offset;
    const next = screen.put(line, col, ch, hit ? base | STYLE_BOLD | STYLE_ACCENT : base, titleEnd);
    if (next === col && textWidth(ch) > 0) break;
    col = next;
    offset += ch.length;
    if (col >= titleEnd) break;
  }
  if (detailWidth > 0) {
    const clipped = clipLeft(detail, detailWidth);
    screen.put(line, screen.cols - textWidth(clipped) - 1, clipped, base | STYLE_DIM);
  }
}

function drawChips(screen: Screen, session: SearchSession): void {
  if (session.mode === MODE_WEB) {
    screen.put(1, 1, "Web search · ⇧⇥ or esc to go back", STYLE_DIM);
    return;
  }
  if (session.query.trim().length === 0) return;
  let col = 1;
  for (const f of visibleFilters(session.counts, session.filter)) {
    const chip = " " + FILTER_TITLES[f] + " " + session.counts[f] + " ";
    if (col + textWidth(chip) > screen.cols) break;
    col = screen.put(1, col, chip, f === session.filter ? STYLE_SELECTED : STYLE_DIM);
    col++;
  }
}

export function render(screen: Screen, session: SearchSession, status: Status): void {
  screen.clear();
  let col = 0;
  if (session.mode === MODE_WEB) {
    col = screen.put(0, 0, " " + engineById(session.engineId).title, STYLE_ACCENT | STYLE_BOLD);
  }
  col = screen.put(0, col, PROMPT, STYLE_ACCENT | STYLE_BOLD);
  const count = session.rows.length;
  const summary = session.query.trim().length === 0 ? "" : count === 1 ? "1 result" : count + " results";
  const queryEnd = screen.cols - textWidth(summary) - 2;
  col = screen.put(0, col, session.query, STYLE_BOLD, queryEnd);
  screen.cursorRow = 0;
  screen.cursorCol = Math.min(col, screen.cols - 1);
  if (summary.length > 0) screen.put(0, screen.cols - textWidth(summary) - 1, summary, STYLE_DIM);
  drawChips(screen, session);
  rule(screen, 2);

  const hasNotice = status.notice.length > 0;
  const visible = listRows(screen.rows, hasNotice);
  if (count === 0) {
    const hint =
      session.query.trim().length > 0
        ? "No results"
        : session.mode === MODE_WEB
          ? "Type to search the web"
          : "Type to search apps, files, settings — or a sum, a unit, a web address";
    screen.put(HEADER_ROWS, 3, hint, STYLE_DIM);
  } else {
    const top = scrollTop(session.selected, count, visible);
    const best = session.topHit();
    for (let i = 0; i < visible && top + i < count; i++) {
      const row = session.rows[top + i];
      drawRow(screen, HEADER_ROWS + i, row, top + i === session.selected, row === best && top + i === 0, status.now);
    }
  }

  const footer = screen.rows - 1;
  if (hasNotice) screen.put(footer - 2, 1, "⚠ " + status.notice, STYLE_ACCENT, screen.cols - 1);
  rule(screen, footer - 1);
  const files =
    status.building && status.fileCount < 0
      ? "indexing…"
      : group(Math.max(0, status.fileCount)) + " files" + (status.building ? " ↻" : "");
  const filesCol = screen.cols - textWidth(files) - 1;
  screen.put(footer, 1, HELP, STYLE_DIM, filesCol - 1);
  screen.put(footer, filesCol, files, STYLE_DIM);
}
