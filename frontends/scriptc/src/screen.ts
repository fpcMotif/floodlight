/**
 * A double-buffered cell grid that writes only what changed.
 *
 * The frame is drawn into `back`; `flush` compares it with `front` (what the
 * terminal shows) and emits, per row, one cursor move and the run from the
 * first to the last changed cell. The whole frame goes out inside a
 * synchronized-update bracket (DEC mode 2026), so terminals that support it
 * swap it atomically and the rest simply ignore it — no flicker either way.
 */

export const STYLE_PLAIN = 0;
export const STYLE_BOLD = 1;
export const STYLE_DIM = 2;
export const STYLE_ACCENT = 4;
export const STYLE_SELECTED = 8;

/** Second half of a double-width character; never printed on its own. */
const WIDE_TAIL = "";

export function charWidth(cp: number): number {
  // Combining marks and zero-width joiners take no cell of their own.
  if ((cp >= 0x300 && cp <= 0x36f) || cp === 0x200d || (cp >= 0xfe00 && cp <= 0xfe0f)) return 0;
  if (cp < 0x1100) return 1;
  // East Asian Wide/Fullwidth blocks and the emoji planes: the ranges that
  // matter for file names. Not a full UAX #11 table.
  if (
    (cp >= 0x1100 && cp <= 0x115f) ||
    (cp >= 0x2e80 && cp <= 0xa4cf && cp !== 0x303f) ||
    (cp >= 0xac00 && cp <= 0xd7a3) ||
    (cp >= 0xf900 && cp <= 0xfaff) ||
    (cp >= 0xfe30 && cp <= 0xfe4f) ||
    (cp >= 0xff00 && cp <= 0xff60) ||
    (cp >= 0xffe0 && cp <= 0xffe6) ||
    (cp >= 0x1f300 && cp <= 0x1faff) ||
    (cp >= 0x20000 && cp <= 0x3fffd)
  ) {
    return 2;
  }
  return 1;
}

export function textWidth(text: string): number {
  let width = 0;
  for (const ch of text) width += charWidth(ch.codePointAt(0) ?? 32);
  return width;
}

export function sgr(style: number): string {
  let codes = "0";
  if ((style & STYLE_BOLD) !== 0) codes += ";1";
  if ((style & STYLE_DIM) !== 0) codes += ";2";
  // The terminal's own blue, so the accent follows its theme.
  if ((style & STYLE_ACCENT) !== 0) codes += ";34";
  if ((style & STYLE_SELECTED) !== 0) codes += ";7";
  return "\x1b[" + codes + "m";
}

export class Screen {
  private backText: string[] = [];
  private backStyle: number[] = [];
  private frontText: string[] = [];
  private frontStyle: number[] = [];
  /** False until the first flush, and after a resize: repaint everything. */
  private valid = false;
  cursorRow = 0;
  cursorCol = 0;

  constructor(
    public rows: number,
    public cols: number,
  ) {
    this.allocate();
  }

  resize(rows: number, cols: number): void {
    if (rows === this.rows && cols === this.cols) return;
    this.rows = rows;
    this.cols = cols;
    this.allocate();
  }

  private allocate(): void {
    const n = this.rows * this.cols;
    this.backText = new Array<string>(n).fill(" ");
    this.backStyle = new Array<number>(n).fill(STYLE_PLAIN);
    this.frontText = new Array<string>(n).fill(" ");
    this.frontStyle = new Array<number>(n).fill(STYLE_PLAIN);
    this.valid = false;
  }

  clear(): void {
    this.backText.fill(" ");
    this.backStyle.fill(STYLE_PLAIN);
  }

  /** Fills a row's remaining cells with `style`, for full-width bars. */
  fillRow(row: number, style: number): void {
    if (row < 0 || row >= this.rows) return;
    const base = row * this.cols;
    for (let c = 0; c < this.cols; c++) this.backStyle[base + c] = style;
  }

  /**
   * Writes `text` at (row, col) and returns the column after it. Clips at
   * `limit` (default: the row end); a wide character that would straddle the
   * limit is replaced with a space rather than split.
   */
  put(row: number, col: number, text: string, style: number, limit: number = -1): number {
    if (row < 0 || row >= this.rows) return col;
    const end = limit < 0 || limit > this.cols ? this.cols : limit;
    const base = row * this.cols;
    let c = col;
    for (const ch of text) {
      const w = charWidth(ch.codePointAt(0) ?? 32);
      if (w === 0) {
        if (c > 0 && c <= end) this.backText[base + c - 1] += ch;
        continue;
      }
      if (c + w > end) {
        while (c < end) {
          this.backText[base + c] = " ";
          this.backStyle[base + c] = style;
          c++;
        }
        break;
      }
      this.backText[base + c] = ch;
      this.backStyle[base + c] = style;
      if (w === 2) {
        this.backText[base + c + 1] = WIDE_TAIL;
        this.backStyle[base + c + 1] = style;
      }
      c += w;
    }
    return c;
  }

  /** The visible text of a back-buffer row, for tests and debugging. */
  rowText(row: number): string {
    return this.backText.slice(row * this.cols, (row + 1) * this.cols).join("");
  }

  /** The escape sequence that brings the terminal from front to back. */
  flush(): string {
    let out = "\x1b[?2026h\x1b[?25l";
    if (!this.valid) out += "\x1b[0m\x1b[2J";
    for (let r = 0; r < this.rows; r++) {
      const base = r * this.cols;
      let first = -1;
      let last = -1;
      for (let c = 0; c < this.cols; c++) {
        const i = base + c;
        if (this.valid && this.backText[i] === this.frontText[i] && this.backStyle[i] === this.frontStyle[i]) {
          continue;
        }
        if (first < 0) first = c;
        last = c;
      }
      if (first < 0) continue;
      // A run must not start or end inside a wide character, old or new:
      // overwriting half of one blanks the other half on most terminals.
      while (first > 0 && (this.backText[base + first] === WIDE_TAIL || this.frontText[base + first] === WIDE_TAIL)) {
        first--;
      }
      while (
        last + 1 < this.cols &&
        (this.backText[base + last + 1] === WIDE_TAIL || this.frontText[base + last + 1] === WIDE_TAIL)
      ) {
        last++;
      }
      out += "\x1b[" + (r + 1) + ";" + (first + 1) + "H";
      let style = -1;
      for (let c = first; c <= last; c++) {
        const i = base + c;
        const text = this.backText[i];
        if (text === WIDE_TAIL) continue;
        if (this.backStyle[i] !== style) {
          style = this.backStyle[i];
          out += sgr(style);
        }
        out += text;
      }
      out += "\x1b[0m";
    }
    for (let i = 0; i < this.backText.length; i++) {
      this.frontText[i] = this.backText[i];
      this.frontStyle[i] = this.backStyle[i];
    }
    this.valid = true;
    out += "\x1b[" + (this.cursorRow + 1) + ";" + (this.cursorCol + 1) + "H\x1b[?25h\x1b[?2026l";
    return out;
  }
}
