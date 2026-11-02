/**
 * Lays the session out on the screen. Pure: session and status in, cells
 * out, so the self-test can check a frame without a terminal.
 *
 *    ❯ saf▏                                         3 results
 *   ─────────────────────────────────────────────────────────
 *    ◆ Safari                                  /Applications
 *    ▸ safari-exports                     ~/Documents/2026
 *    · Safari Bookmarks.html              ~/Desktop
 *   ─────────────────────────────────────────────────────────
 *    ↑↓ select  ⏎ open  ⌥⏎ reveal  esc quit      412,331 files
 */
import { KIND_APP, KIND_FOLDER, Row, SearchSession } from "./session";
import {
  Screen,
  STYLE_ACCENT,
  STYLE_BOLD,
  STYLE_DIM,
  STYLE_PLAIN,
  STYLE_SELECTED,
  textWidth,
} from "./screen";

export class Status {
  constructor(
    /** Entries in the file index; negative while the first build runs. */
    readonly fileCount: number,
    readonly building: boolean,
  ) {}
}

const PROMPT = " ❯ ";
const GLYPH_APP = "◆";
const GLYPH_FOLDER = "▸";
const GLYPH_FILE = "·";
const HEADER_ROWS = 2;
const FOOTER_ROWS = 2;

/** Rows available for results at a given screen height. */
export function listRows(screenRows: number): number {
  return Math.max(1, screenRows - HEADER_ROWS - FOOTER_ROWS);
}

/** First visible result, keeping the selection on screen. */
export function scrollTop(selected: number, count: number, visible: number): number {
  if (count <= visible) return 0;
  const top = selected - visible + 1;
  return Math.max(0, Math.min(top, count - visible));
}

function group(n: number): string {
  const digits = String(n);
  let out = "";
  for (let i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 === 0) out += ",";
    out += digits.charAt(i);
  }
  return out;
}

/** Keeps the tail of a path, which is the part that tells two apart. */
function clipLeft(text: string, width: number): string {
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

function rule(screen: Screen, row: number): void {
  screen.put(row, 0, "─".repeat(screen.cols), STYLE_DIM);
}

function drawRow(screen: Screen, line: number, row: Row, selected: boolean): void {
  const base = selected ? STYLE_SELECTED : STYLE_PLAIN;
  if (selected) screen.fillRow(line, base);
  const glyph = row.kind === KIND_APP ? GLYPH_APP : row.kind === KIND_FOLDER ? GLYPH_FOLDER : GLYPH_FILE;
  let col = screen.put(line, 0, " ", base);
  col = screen.put(line, col, glyph, base | STYLE_ACCENT);
  col = screen.put(line, col, " ", base);

  // Detail takes the right side, but never more than half the row.
  const detailWidth = Math.min(textWidth(row.detail), Math.floor((screen.cols - col) / 2));
  const titleEnd = screen.cols - detailWidth - 2;
  const chars = Array.from(row.title);
  let offset = 0;
  let mark = 0;
  for (const ch of chars) {
    while (mark < row.marks.length && row.marks[mark] < offset) mark++;
    const hit = mark < row.marks.length && row.marks[mark] === offset;
    const style = hit ? base | STYLE_BOLD | STYLE_ACCENT : base;
    const next = screen.put(line, col, ch, style, titleEnd);
    if (next === col && textWidth(ch) > 0) break;
    col = next;
    offset += ch.length;
    if (col >= titleEnd) break;
  }
  if (detailWidth > 0) {
    const detail = clipLeft(row.detail, detailWidth);
    screen.put(line, screen.cols - textWidth(detail) - 1, detail, base | STYLE_DIM);
  }
}

export function render(screen: Screen, session: SearchSession, status: Status): void {
  screen.clear();
  let col = screen.put(0, 0, PROMPT, STYLE_ACCENT | STYLE_BOLD);
  const count = session.rows.length;
  const summary = session.query.trim().length === 0 ? "" : count === 1 ? "1 result" : count + " results";
  const queryEnd = screen.cols - textWidth(summary) - 2;
  col = screen.put(0, col, session.query, STYLE_BOLD, queryEnd);
  screen.cursorRow = 0;
  screen.cursorCol = Math.min(col, screen.cols - 1);
  if (summary.length > 0) screen.put(0, screen.cols - textWidth(summary) - 1, summary, STYLE_DIM);
  rule(screen, 1);

  const visible = listRows(screen.rows);
  if (count === 0) {
    const hint = session.query.trim().length === 0 ? "Type to search apps and files" : "No results";
    screen.put(HEADER_ROWS, 3, hint, STYLE_DIM);
  } else {
    const top = scrollTop(session.selected, count, visible);
    for (let i = 0; i < visible && top + i < count; i++) {
      drawRow(screen, HEADER_ROWS + i, session.rows[top + i], top + i === session.selected);
    }
  }

  const footer = screen.rows - 1;
  rule(screen, footer - 1);
  const files =
    status.building && status.fileCount < 0
      ? "indexing…"
      : group(Math.max(0, status.fileCount)) + " files" + (status.building ? " ↻" : "");
  const filesCol = screen.cols - textWidth(files) - 1;
  screen.put(footer, 1, "↑↓ select  ⏎ open  ⌥⏎ reveal  esc quit", STYLE_DIM, filesCol - 1);
  screen.put(footer, filesCol, files, STYLE_DIM);
}
