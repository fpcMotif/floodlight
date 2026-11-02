/**
 * The frontend's behavioural tests, compiled by scriptc like the app itself
 * so they exercise the generated native code, not a JavaScript engine.
 *
 * Frames are checked the way a terminal would see them: the escape stream
 * from Screen.flush is replayed into a small VT emulator, and the emulator's
 * cells must equal what the view drew. That covers the diff renderer's whole
 * job — emit less, but never leave a stale cell behind.
 */
import { fuzzyMatch } from "../src/match";
import { Key, KEY_DOWN, KEY_ESCAPE, KEY_REVEAL, KEY_TEXT, KEY_UP, KEY_PAGE_DOWN, KeyParser } from "../src/keys";
import { App, FileSource, KIND_APP, KIND_FILE, KIND_FOLDER, Row, SearchSession } from "../src/session";
import { ACTION_OPEN, extensionOf } from "../src/row";
import { check, eq, eqn, Tally } from "./check";
import { boardKeyName } from "../src/keys";
import { FDA_GRANTED, FDA_JUST_GRANTED, FDA_MISSING, FDA_WAITING, FdaFlow } from "../src/fda";
import { Palette, sgr, STYLE_SELECTED, swatch } from "../src/screen";
import { formatBytes, formatNumber } from "../src/format";
import { runParity } from "./parity";
import { Screen, STYLE_PLAIN, charWidth } from "../src/screen";
import { render, scrollTop, Status } from "../src/view";
import { displayPath } from "../src/paths";

// ---- a minimal VT emulator ------------------------------------------------

/** Understands exactly what Screen emits: CUP, SGR, ED 2, private modes. */
class Terminal {
  cells: string[];
  constructor(
    readonly rows: number,
    readonly cols: number,
  ) {
    this.cells = new Array<string>(rows * cols).fill(" ");
  }

  feed(stream: string): void {
    const chars = Array.from(stream);
    let row = 0;
    let col = 0;
    let i = 0;
    while (i < chars.length) {
      const ch = chars[i];
      if (ch === "\x1b") {
        // ESC [ params final
        let j = i + 2;
        while (j < chars.length && !/[A-Za-z]/.test(chars[j])) j++;
        const params = chars.slice(i + 2, j).join("");
        const final = chars[j];
        if (final === "H") {
          const parts = params.split(";");
          row = parseInt(parts[0], 10) - 1;
          col = parseInt(parts[1], 10) - 1;
        } else if (final === "J" && params === "2") {
          this.cells.fill(" ");
        }
        i = j + 1;
        continue;
      }
      const w = charWidth(ch.codePointAt(0) ?? 32);
      if (w === 0) {
        this.cells[row * this.cols + col - 1] += ch;
      } else {
        this.cells[row * this.cols + col] = ch;
        if (w === 2) this.cells[row * this.cols + col + 1] = "";
        col += w;
      }
      i++;
    }
  }

  rowText(row: number): string {
    return this.cells.slice(row * this.cols, (row + 1) * this.cols).join("");
  }
}

function sameScreen(term: Terminal, screen: Screen, what: string): void {
  for (let r = 0; r < screen.rows; r++) eq(term.rowText(r), screen.rowText(r), what + " row " + r);
}

// ---- fixtures -------------------------------------------------------------

class FakeFiles extends FileSource {
  queries: string[] = [];
  constructor(private readonly rows: Row[]) {
    super();
  }
  count(): number {
    return this.rows.length;
  }
  search(query: string, limit: number): Row[] {
    this.queries.push(query);
    const q = query.toLowerCase();
    const out: Row[] = [];
    for (const row of this.rows) {
      if (out.length >= limit) break;
      if (row.title.toLowerCase().indexOf(q) >= 0) out.push(row);
    }
    return out;
  }
}

function file(title: string, dir: string, kind: number = KIND_FILE): Row {
  const path = dir + "/" + title;
  return new Row(kind, "file:" + path, title, dir, path, ACTION_OPEN, [], 1, extensionOf(title));
}

const APPS = [
  new App("Safari", "/Applications/Safari.app", "/Applications"),
  new App("Visual Studio Code", "/Applications/Visual Studio Code.app", "/Applications"),
  new App("System Settings", "/System/Applications/System Settings.app", "/System/Applications"),
  new App("Terminal", "/System/Applications/Utilities/Terminal.app", "/System/Applications/Utilities"),
  new App("TextEdit", "/System/Applications/TextEdit.app", "/System/Applications"),
];

const FILES = [
  file("safari-notes.md", "~/Documents"),
  file("terminal.log", "~/Library/Logs"),
  file("日本語メモ.txt", "~/Desktop"),
  file("Safari.app", "/Applications", KIND_FOLDER),
];

// ---- matcher --------------------------------------------------------------

function testMatcher(): void {
  const prefix = fuzzyMatch("Safari", "saf");
  check(prefix !== null, "prefix matches");
  if (prefix !== null) eq(prefix.positions.join(","), "0,1,2", "prefix positions");

  const acronym = fuzzyMatch("Visual Studio Code", "vsc");
  check(acronym !== null, "acronym matches");
  if (acronym !== null) eq(acronym.positions.join(","), "0,7,14", "acronym picks word starts");

  const camel = fuzzyMatch("TextEdit", "te");
  if (camel !== null) eq(camel.positions.join(","), "0,1", "consecutive beats camel boundary");

  check(fuzzyMatch("Safari", "xyz") === null, "no match is null");
  check(fuzzyMatch("Safari", "fas") === null, "order matters");

  const a = fuzzyMatch("Terminal", "term");
  const b = fuzzyMatch("System Settings", "term");
  check(a !== null && (b === null || a.score > b.score), "prefix outranks scattered");
}

// ---- keys -----------------------------------------------------------------

function bytes(text: string): Uint8Array {
  return new Uint8Array(Buffer.from(text, "utf8"));
}

function codes(keys: Key[]): string {
  return keys.map((k) => (k.code === KEY_TEXT ? "t:" + k.text : String(k.code))).join(" ");
}

function testKeys(): void {
  const p = new KeyParser();
  let b = bytes("ab\x1b[A\x1b[B\x1bOAc");
  eq(codes(p.feed(b, b.length)), "t:ab " + KEY_UP + " " + KEY_DOWN + " " + KEY_UP + " t:c", "CSI and SS3 arrows");

  b = bytes("\x1b[");
  eq(codes(p.feed(b, b.length)), "", "cut-off sequence waits");
  b = bytes("6~x");
  eq(codes(p.feed(b, b.length)), KEY_PAGE_DOWN + " t:x", "sequence completes on the next read");

  const utf8 = bytes("é");
  eq(codes(p.feed(utf8, 1)), "", "split code point waits");
  eq(codes(p.feed(utf8.subarray(1), 1)), "t:é", "split code point completes");

  b = bytes("\x1b");
  eq(codes(p.feed(b, b.length)), "", "lone ESC is held");
  check(p.hasPendingEscape(), "lone ESC is reported pending");
  eq(codes(p.flushEscape()), String(KEY_ESCAPE), "lone ESC becomes Escape after the wait");

  b = bytes("\x1b\r");
  eq(codes(p.feed(b, b.length)), String(KEY_REVEAL), "Alt-Enter reveals");

  b = bytes("\x1b[1;5D");
  eq(codes(p.feed(b, b.length)), "", "unbound sequences are dropped, not typed");
}

// ---- session --------------------------------------------------------------

function testSession(): void {
  const files = new FakeFiles(FILES);
  const s = new SearchSession(APPS, files);

  s.setQuery("");
  eqn(s.rows.length, 0, "empty query shows nothing");
  eqn(files.queries.length, 0, "empty query never reaches the index");

  s.setQuery("saf");
  eq(
    s.rows.map((r) => r.title).join("|"),
    "Safari|safari-notes.md|Google",
    "apps first, duplicate bundle hidden, web row last",
  );
  eqn(s.rows[0].kind, KIND_APP, "top row is the app");
  eq(s.rows[0].marks.join(","), "0,1,2", "app row carries highlight marks");

  s.move(5);
  eqn(s.selected, 2, "move clamps at the end");
  s.move(-5);
  eqn(s.selected, 0, "move clamps at the start");
  s.move(1);
  s.setQuery("safa");
  eqn(s.selected, 0, "a new query resets the selection");

  s.setQuery("vsc");
  eq(s.current() === null ? "" : s.current()!.title, "Visual Studio Code", "acronym finds the app");

  s.setQuery("  ");
  eqn(s.rows.length, 0, "blank query shows nothing");

  const gen = s.generation;
  s.move(1);
  eqn(s.generation, gen, "a no-op move does not republish");
}

// ---- screen and view ------------------------------------------------------

function testDiffRenderer(): void {
  const screen = new Screen(4, 12);
  const term = new Terminal(4, 12);
  screen.put(0, 0, "hello", STYLE_PLAIN);
  screen.put(2, 3, "日本", STYLE_PLAIN);
  term.feed(screen.flush());
  sameScreen(term, screen, "first frame");

  screen.clear();
  screen.put(0, 0, "help", STYLE_PLAIN);
  screen.put(2, 4, "ab", STYLE_PLAIN);
  const second = screen.flush();
  term.feed(second);
  sameScreen(term, screen, "second frame");
  check(second.indexOf("\x1b[2;") < 0, "unchanged rows are not rewritten");

  const idle = screen.flush();
  check(idle.indexOf("help") < 0, "an identical frame writes no cells");

  const clipped = new Screen(1, 5);
  clipped.put(0, 0, "abcd日", STYLE_PLAIN);
  eq(clipped.rowText(0), "abcd ", "a wide char never straddles the edge");
}

function testView(): void {
  const s = new SearchSession(APPS, new FakeFiles(FILES));
  const screen = new Screen(10, 60);
  const term = new Terminal(10, 60);

  render(screen, s, new Status(-1, true));
  term.feed(screen.flush());
  sameScreen(term, screen, "empty view");
  check(screen.rowText(3).indexOf("Type to search") >= 0, "empty state hint");
  check(screen.rowText(9).indexOf("indexing…") >= 0, "first build shows indexing");

  s.setQuery("t");
  render(screen, s, new Status(1234567, false));
  term.feed(screen.flush());
  sameScreen(term, screen, "results view");
  check(screen.rowText(0).indexOf(" t") >= 0, "query on the prompt row");
  check(screen.rowText(3).indexOf("Terminal") >= 0, "best app on the first row");
  check(screen.rowText(3).indexOf("★") >= 0, "the top hit is marked");
  check(screen.rowText(1).indexOf("Apps") >= 0, "filter chips under the prompt");
  check(screen.rowText(9).indexOf("1,234,567 files") >= 0, "file count is grouped");
  eqn(screen.cursorRow, 0, "cursor sits on the prompt");

  s.setQuery("日本");
  render(screen, s, new Status(4, false));
  term.feed(screen.flush());
  sameScreen(term, screen, "wide-character results");

  eqn(scrollTop(0, 100, 10), 0, "scroll starts at the top");
  eqn(scrollTop(15, 100, 10), 6, "scroll keeps the selection on the last line");
  eqn(scrollTop(99, 100, 10), 90, "scroll stops at the end");
}

function testPaths(): void {
  eq(displayPath("/Users/me/Documents", "/Users/me"), "~/Documents", "home abbreviates");
  eq(displayPath("/Users/meow", "/Users/me"), "/Users/meow", "a sibling prefix does not");
}

function testWidth(): void {
  eqn(charWidth("a".codePointAt(0) ?? 0), 1, "ASCII is narrow");
  eqn(charWidth("日".codePointAt(0) ?? 0), 2, "CJK is wide");
  eqn(charWidth(0x301), 0, "combining marks take no cell");
}

function testBoardKeys(): void {
  const p = new KeyParser();
  const names = (text: string): string => {
    const b = bytes(text);
    return p
      .feed(b, b.length)
      .map((k) => boardKeyName(k))
      .join(" ");
  };
  eq(names("\r"), "return", "Enter pastes");
  eq(names("\x1b\r"), "option+return", "Alt-Enter is ⌥Return");
  eq(names("\x1bc\x1br\x1by\x1bk\x1b.\x1bd\x1b3"), "cmd+c cmd+r cmd+y cmd+k cmd+. cmd+d cmd+3", "Alt stands in for ⌘");
  eq(names("\x19\x0b\x04\x0f"), "cmd+y cmd+k cmd+d cmd+return", "Ctrl chords are a second spelling");
  eq(names(" "), "space", "a lone space");
  eq(names("ab"), "text:ab", "typing");
  eq(names("\t\x1b[Z"), " ", "Tab and Shift-Tab mean nothing on the board");
}

function testFda(): void {
  const f = new FdaFlow();
  f.start(1);
  eqn(f.state, FDA_GRANTED, "granted at start: no notice");
  check(!f.polling(), "granted: no polling");
  f.start(0);
  eqn(f.state, FDA_MISSING, "missing: the notice shows");
  check(f.notice("Ghostty.app").indexOf("^G") >= 0, "the notice names the key");
  check(f.beginGrant(), "the grant starts");
  eqn(f.state, FDA_WAITING, "waiting for the drag");
  check(f.notice("Ghostty.app").indexOf("Ghostty.app") >= 0, "the notice names the terminal");
  check(!f.tick(0, 100), "no grant yet");
  check(f.tick(1, 101), "the grant lands once");
  eqn(f.state, FDA_JUST_GRANTED, "says granted");
  check(!f.tick(1, 102), "and only once");
  f.tick(1, 105);
  eqn(f.state, FDA_GRANTED, "then the notice goes");
}

function testPalette(): void {
  Palette.detect("truecolor");
  check(sgr(STYLE_SELECTED).indexOf("48;2;10;132;255") >= 0, "truecolor selection is system blue");
  check(sgr(swatch(0xff8800)).indexOf("48;2;255;136;0") >= 0, "a colour swatch in truecolor");
  Palette.detect("");
  check(sgr(STYLE_SELECTED).indexOf(";7") >= 0, "16 colours: reverse video");
  check(sgr(swatch(0xff8800)).indexOf(";43") >= 0, "16 colours: the nearest ANSI background");
  eq(formatNumber(1234567.5), "1,234,567.5", "grouped answer");
  eq(formatNumber(0.1 + 0.2), "0.3", "ten fraction digits, trailing zeros dropped");
  eq(formatBytes(12345), "12 KB", "Finder-style sizes");
}

testMatcher();
testBoardKeys();
testFda();
testPalette();
testKeys();
testSession();
testDiffRenderer();
testView();
testPaths();
testWidth();

const fixtures = process.argv.length > 2 ? process.argv[2] : "../../fixtures/parity";
runParity(fixtures);

console.log("selftest: " + (Tally.checks - Tally.failures) + "/" + Tally.checks + " checks passed");
if (Tally.failures > 0) process.exit(1);
