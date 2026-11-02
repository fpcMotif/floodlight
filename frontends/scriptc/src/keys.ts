/**
 * Turns raw terminal input bytes into key events.
 *
 * Covers what a launcher needs from xterm-style terminals (Ghostty, iTerm2,
 * Terminal.app, kitty, Alacritty): printable UTF-8, the arrow and page keys
 * in both CSI (`ESC [ A`) and SS3 (`ESC O A`) forms, and a few control keys.
 * Anything else is dropped, never inserted as text.
 */

export const KEY_TEXT = 0;
export const KEY_UP = 1;
export const KEY_DOWN = 2;
export const KEY_PAGE_UP = 3;
export const KEY_PAGE_DOWN = 4;
export const KEY_ENTER = 5;
/** Alt/Option-Enter: reveal in Finder, the terminal's stand-in for ⌘Enter. */
export const KEY_REVEAL = 6;
export const KEY_ESCAPE = 7;
export const KEY_BACKSPACE = 8;
/** Ctrl-U: clear the query. */
export const KEY_CLEAR = 9;
/** Ctrl-W or Alt-Backspace: delete the last word. */
export const KEY_DELETE_WORD = 10;
/** Ctrl-C or Ctrl-D: quit regardless of state. */
export const KEY_QUIT = 11;

export class Key {
  constructor(
    readonly code: number,
    readonly text: string,
  ) {}
}

const ESC = 0x1b;

function utf8Length(lead: number): number {
  if (lead < 0x80) return 1;
  if (lead >= 0xf0) return 4;
  if (lead >= 0xe0) return 3;
  if (lead >= 0xc0) return 2;
  return 0;
}

export class KeyParser {
  private pending: number[] = [];

  /** True when the buffered bytes end in a lone ESC, which is either the
   * Escape key or the first byte of a sequence still in flight. The caller
   * waits briefly for more input before calling `flushEscape`. */
  hasPendingEscape(): boolean {
    return this.pending.length === 1 && this.pending[0] === ESC;
  }

  flushEscape(): Key[] {
    if (!this.hasPendingEscape()) return [];
    this.pending = [];
    return [new Key(KEY_ESCAPE, "")];
  }

  feed(bytes: Uint8Array, length: number): Key[] {
    for (let i = 0; i < length; i++) this.pending.push(bytes[i]);
    const keys: Key[] = [];
    const buf = this.pending;
    let i = 0;
    while (i < buf.length) {
      const b = buf[i];
      if (b === ESC) {
        const used = this.escape(buf, i, keys);
        if (used === 0) break; // incomplete sequence: keep for the next read
        i += used;
        continue;
      }
      if (b === 13 || b === 10) keys.push(new Key(KEY_ENTER, ""));
      else if (b === 127 || b === 8) keys.push(new Key(KEY_BACKSPACE, ""));
      else if (b === 21) keys.push(new Key(KEY_CLEAR, ""));
      else if (b === 23) keys.push(new Key(KEY_DELETE_WORD, ""));
      else if (b === 3 || b === 4) keys.push(new Key(KEY_QUIT, ""));
      else if (b === 16) keys.push(new Key(KEY_UP, "")); // Ctrl-P
      else if (b === 14) keys.push(new Key(KEY_DOWN, "")); // Ctrl-N
      else if (b >= 0x20) {
        const n = utf8Length(b);
        if (n === 0) {
          i++;
          continue;
        }
        if (i + n > buf.length) break; // split code point: wait for the rest
        keys.push(new Key(KEY_TEXT, Buffer.from(buf.slice(i, i + n)).toString("utf8")));
        i += n;
        continue;
      }
      i++;
    }
    this.pending = buf.slice(i);
    return mergeText(keys);
  }

  /** Bytes consumed by the escape sequence at `i`, or 0 if it is cut off. */
  private escape(buf: number[], i: number, keys: Key[]): number {
    if (i + 1 >= buf.length) return 0;
    const next = buf[i + 1];
    if (next === 13) {
      keys.push(new Key(KEY_REVEAL, ""));
      return 2;
    }
    if (next === 127) {
      keys.push(new Key(KEY_DELETE_WORD, ""));
      return 2;
    }
    if (next === ESC) {
      keys.push(new Key(KEY_ESCAPE, ""));
      return 1;
    }
    if (next !== 0x5b && next !== 0x4f) {
      // ESC + printable is Alt+key; the launcher has no Alt bindings yet.
      return 2;
    }
    // CSI / SS3: parameters, then one final byte in 0x40..0x7e.
    let j = i + 2;
    while (j < buf.length && (buf[j] < 0x40 || buf[j] > 0x7e)) j++;
    if (j >= buf.length) return 0;
    const final = buf[j];
    const params = Buffer.from(buf.slice(i + 2, j)).toString("utf8");
    if (final === 0x41) keys.push(new Key(KEY_UP, ""));
    else if (final === 0x42) keys.push(new Key(KEY_DOWN, ""));
    else if (final === 0x7e && params === "5") keys.push(new Key(KEY_PAGE_UP, ""));
    else if (final === 0x7e && params === "6") keys.push(new Key(KEY_PAGE_DOWN, ""));
    else if (final === 0x75 && params === "27") keys.push(new Key(KEY_ESCAPE, "")); // kitty CSI u
    else if (final === 0x75 && params === "13;3") keys.push(new Key(KEY_REVEAL, ""));
    return j - i + 1;
  }
}

/** Collapses a paste or a burst of typing into one text event, so the session
 * runs one query for it rather than one per character. */
function mergeText(keys: Key[]): Key[] {
  const out: Key[] = [];
  for (const key of keys) {
    const last = out.length > 0 ? out[out.length - 1] : null;
    if (key.code === KEY_TEXT && last !== null && last.code === KEY_TEXT) {
      out[out.length - 1] = new Key(KEY_TEXT, last.text + key.text);
    } else {
      out.push(key);
    }
  }
  return out;
}
