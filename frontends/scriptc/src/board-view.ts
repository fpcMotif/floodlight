/**
 * The clipboard board as a split view: the list on the left, the inspector
 * on the right, the keys along the bottom. The terminal's version of the
 * 840 × 560 pt board, sized to whatever the terminal is.
 *
 *    Clipboard ❯ lin                                          3 entries
 *    All   Text   Files   Images
 *   ──────────────────────────┬─────────────────────────────────────────
 *    ↗ github.com/fpc…    5m │ https://github.com/fpcMotif/floodlight
 *    ¶ Meeting notes      2h │ Safari · 5m
 *                            │
 *                            │ Link · github.com
 *   ──────────────────────────┴─────────────────────────────────────────
 *    ⏎ paste ⌥⏎ copy ⌥R reveal ^Y preview ⌥K actions ⌥. pin ⌥D delete
 */
import {
  BOARD_FILTER_TITLES,
  ClipBoard,
  MENU_COPY,
  MENU_DELETE,
  MENU_PASTE,
  MENU_PIN,
  MENU_PREVIEW,
  MENU_REVEAL,
} from "./clip-board";
import {
  CLIP_IMAGE,
  ClipEntry,
  CONTENT_CODE,
  CONTENT_COLOR,
  CONTENT_LINK,
  entryBadge,
  entryDetail,
  entryPath,
  entryTitle,
  parseHexColor,
} from "./clip-entry";
import { formatAge, formatBytes, group } from "./format";
import { rule } from "./view";
import { Screen, STYLE_ACCENT, STYLE_BOLD, STYLE_DIM, STYLE_PLAIN, STYLE_SELECTED, swatch, textWidth } from "./screen";

/** What the inspector needs from outside the board: the platform's answers. */
export abstract class BoardFacts {
  abstract appName(bundleId: string): string;
  abstract fullText(entry: ClipEntry): string;
  /** Bytes, or -1 when nothing is at the path. */
  abstract fileSize(path: string): number;
}

const HEADER_ROWS = 3;
const FOOTER_ROWS = 2;
const HELP = "⏎ paste ⌥⏎ copy ⌥R reveal ^Y preview ⌥K actions ⌥. pin ⌥D delete ⌥1-4 filter esc";

export function glyph(entry: ClipEntry): string {
  const b = entryBadge(entry);
  if (b === "link") return "↗";
  if (b === "color") return "■";
  if (b === "code") return "{";
  if (b === "path" || b === "file") return "▤";
  if (b === "image") return "▣";
  return "¶";
}

const MENU_TITLES = new Map<string, string>([
  [MENU_PASTE, "Paste"],
  [MENU_COPY, "Copy"],
  [MENU_REVEAL, "Show in Finder"],
  [MENU_PREVIEW, "Quick Look"],
  [MENU_PIN, "Pin / Unpin"],
  [MENU_DELETE, "Delete"],
]);

/** Splits `text` into lines no wider than `width`, breaking at spaces when it can. */
export function wrap(text: string, width: number, maxLines: number): string[] {
  const out: string[] = [];
  if (width <= 0) return out;
  for (const paragraph of text.split("\n")) {
    let line = "";
    let used = 0;
    for (const ch of Array.from(paragraph.split("\t").join("  "))) {
      const w = textWidth(ch);
      if (used + w > width) {
        const space = line.lastIndexOf(" ");
        if (space > 0 && space > line.length / 2) {
          out.push(line.slice(0, space));
          line = line.slice(space + 1);
          used = textWidth(line);
        } else {
          out.push(line);
          line = "";
          used = 0;
        }
        if (out.length >= maxLines) return out;
      }
      line += ch;
      used += w;
    }
    out.push(line);
    if (out.length >= maxLines) return out;
  }
  return out;
}

export class TextCounts {
  constructor(
    readonly characters: number,
    readonly words: number,
    readonly lines: number,
  ) {}
}

export function countText(text: string): TextCounts {
  let characters = 0;
  let words = 0;
  let lines = text.length === 0 ? 0 : 1;
  let inWord = false;
  for (const ch of text) {
    characters++;
    if (ch === "\n") lines++;
    const space = ch === " " || ch === "\n" || ch === "\t" || ch === "\r";
    if (!space && !inWord) words++;
    inWord = !space;
  }
  return new TextCounts(characters, words, lines);
}

/** "Safari · 5m · Documents": the Swift board's subtitle. */
export function entrySubtitle(entry: ClipEntry, appName: string, now: number): string {
  const detail = entryDetail(entry);
  const head = (appName.length > 0 ? appName : "Clipboard") + " · " + formatAge(entry.createdAt, now);
  return detail.length > 0 ? head + " · " + detail : head;
}

function drawList(screen: Screen, board: ClipBoard, width: number, rows: number): void {
  const count = board.entries.length;
  let top = 0;
  if (board.selected >= rows) top = board.selected - rows + 1;
  for (let i = 0; i < rows && top + i < count; i++) {
    const entry = board.entries[top + i];
    const line = HEADER_ROWS + i;
    const selected = top + i === board.selected;
    const base = selected ? STYLE_SELECTED : STYLE_PLAIN;
    for (let c = 0; c < width; c++) screen.put(line, c, " ", base);
    let col = screen.put(line, 0, entry.isPinned() ? "•" : " ", base | STYLE_ACCENT);
    const color = entry.contentKind === CONTENT_COLOR ? parseHexColor(entry.contentDetail) : null;
    const g = glyph(entry);
    col = screen.put(
      line,
      col,
      g,
      color !== null ? swatch(color.r * 65536 + color.g * 256 + color.b) : base | STYLE_ACCENT,
    );
    col = screen.put(line, col, " ", base);
    const age = formatAge(entry.createdAt, board.now);
    const titleEnd = width - textWidth(age) - 2;
    screen.put(line, col, entryTitle(entry), base, titleEnd);
    screen.put(line, width - textWidth(age) - 1, age, base | STYLE_DIM);
  }
  if (count === 0) {
    screen.put(HEADER_ROWS, 2, board.query.length > 0 ? "No matches" : "Nothing copied yet", STYLE_DIM, width);
  }
}

function inspectorLines(entry: ClipEntry, facts: BoardFacts, width: number, height: number): string[] {
  const lines: string[] = [];
  const kind = entryBadge(entry);
  if (entry.kind === CLIP_IMAGE) {
    lines.push("Image · " + entry.imageWidth + "×" + entry.imageHeight + " · " + formatBytes(entry.imageBytes));
    lines.push("^Y opens it in Quick Look.");
    return lines;
  }
  const path = entryPath(entry);
  if (path.length > 0) {
    const size = facts.fileSize(path);
    lines.push(path);
    lines.push(size >= 0 ? "File · " + formatBytes(size) : "Nothing is at this path any more.");
    return lines;
  }
  const text = facts.fullText(entry);
  const counts = countText(text);
  let facts1 =
    group(counts.characters) + " characters · " + group(counts.words) + " words · " + group(counts.lines) + " lines";
  if (kind === CONTENT_LINK) facts1 = "Link · " + entry.contentDetail + " · " + facts1;
  if (kind === CONTENT_CODE) facts1 = "Code · " + entry.contentDetail + " · " + facts1;
  if (kind === CONTENT_COLOR) {
    const c = parseHexColor(entry.contentDetail);
    if (c !== null) facts1 = "Colour · " + c.hex() + " · " + c.css();
  }
  lines.push(facts1);
  lines.push("");
  for (const l of wrap(text, width, Math.max(1, height - 2))) lines.push(l);
  return lines;
}

function drawInspector(screen: Screen, board: ClipBoard, facts: BoardFacts, left: number, rows: number): void {
  const entry = board.current();
  const width = screen.cols - left - 1;
  if (entry === null || width < 8) return;
  let line = HEADER_ROWS;
  screen.put(line++, left, entryTitle(entry), STYLE_BOLD, screen.cols - 1);
  screen.put(line++, left, entrySubtitle(entry, facts.appName(entry.sourceApp), board.now), STYLE_DIM, screen.cols - 1);
  if (entry.contentKind === CONTENT_COLOR) {
    const c = parseHexColor(entry.contentDetail);
    if (c !== null) screen.put(line, left, "      ", swatch(c.r * 65536 + c.g * 256 + c.b));
  }
  line++;
  const body = inspectorLines(entry, facts, width, rows - 3);
  for (const text of body) {
    if (line >= HEADER_ROWS + rows) break;
    screen.put(line++, left, text, STYLE_PLAIN, screen.cols - 1);
  }
  if (board.menuOpen) drawMenu(screen, board, left, rows);
}

function drawMenu(screen: Screen, board: ClipBoard, left: number, rows: number): void {
  const items = board.menuItems();
  const width = 22;
  const top = HEADER_ROWS + 1;
  if (items.length + 2 > rows) return;
  screen.put(top, left, "┌" + "─".repeat(width - 2) + "┐", STYLE_DIM);
  for (let i = 0; i < items.length; i++) {
    const style = i === board.menuSelected ? STYLE_SELECTED : STYLE_PLAIN;
    const label = " " + (MENU_TITLES.get(items[i]) ?? items[i]);
    screen.put(top + 1 + i, left, "│", STYLE_DIM);
    const end = screen.put(top + 1 + i, left + 1, label, style, left + width - 1);
    for (let c = end; c < left + width - 1; c++) screen.put(top + 1 + i, c, " ", style);
    screen.put(top + 1 + i, left + width - 1, "│", STYLE_DIM);
  }
  screen.put(top + 1 + items.length, left, "└" + "─".repeat(width - 2) + "┘", STYLE_DIM);
}

export function renderBoard(screen: Screen, board: ClipBoard, facts: BoardFacts): void {
  screen.clear();
  let col = screen.put(0, 0, " Clipboard", STYLE_ACCENT | STYLE_BOLD);
  col = screen.put(0, col, " ❯ ", STYLE_ACCENT | STYLE_BOLD);
  const n = board.entries.length;
  const summary = n === 1 ? "1 entry" : group(n) + " entries";
  col = screen.put(0, col, board.query, STYLE_BOLD, screen.cols - textWidth(summary) - 2);
  screen.cursorRow = 0;
  screen.cursorCol = Math.min(col, screen.cols - 1);
  screen.put(0, screen.cols - textWidth(summary) - 1, summary, STYLE_DIM);

  let chip = 1;
  for (let f = 0; f < BOARD_FILTER_TITLES.length; f++) {
    chip = screen.put(1, chip, " " + BOARD_FILTER_TITLES[f] + " ", f === board.filter ? STYLE_SELECTED : STYLE_DIM);
    chip++;
  }

  // The list takes 3/7 of the width, as the 360 pt list does of 840 pt.
  const listWidth = Math.max(16, Math.min(screen.cols - 20, Math.floor((screen.cols * 3) / 7)));
  const rows = Math.max(1, screen.rows - HEADER_ROWS - FOOTER_ROWS);
  rule(screen, 2);
  screen.put(2, listWidth, "┬", STYLE_DIM);
  for (let r = 0; r < rows; r++) screen.put(HEADER_ROWS + r, listWidth, "│", STYLE_DIM);
  drawList(screen, board, listWidth, rows);
  drawInspector(screen, board, facts, listWidth + 2, rows);

  const footer = screen.rows - 1;
  rule(screen, footer - 1);
  screen.put(footer - 1, listWidth, "┴", STYLE_DIM);
  screen.put(footer, 1, HELP, STYLE_DIM, screen.cols - 1);
}
