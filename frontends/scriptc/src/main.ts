/**
 * floodlight-tui: Floodlight's launcher and clipboard board as a terminal
 * program.
 *
 * One thread, one blocking loop: wait for input, apply every key that has
 * arrived, run the query once for the newest text, draw the difference. A
 * burst of typing therefore costs one search, not one per key — latest wins
 * without any cancellation machinery, because nothing runs concurrently.
 * The only other thread is the index rebuild inside the C shim.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { applicationFolders, loadApps } from "./apps";
import { BoardAction, ClipBoard } from "./clip-board";
import { CLIP_IMAGE, ClipEntry, entryPath } from "./clip-entry";
import { SqliteClipStore } from "./clip-sqlite";
import { BoardFacts, renderBoard } from "./board-view";
import { FDA_SETTINGS_URL, FdaFlow, POLL_MS } from "./fda";
import { CoreFiles } from "./files";
import { FILTER_COUNT, visibleFilters } from "./filters";
import {
  boardKeyName,
  KEY_ALT,
  KEY_BACKSPACE,
  KEY_CLEAR,
  KEY_CTRL,
  KEY_DELETE_WORD,
  KEY_DOWN,
  KEY_ENTER,
  KEY_ESCAPE,
  KEY_LEFT,
  KEY_PAGE_DOWN,
  KEY_PAGE_UP,
  KEY_QUIT,
  KEY_REVEAL,
  KEY_RIGHT,
  KEY_SHIFT_TAB,
  KEY_TAB,
  KEY_TEXT,
  KEY_UP,
  Key,
  KeyParser,
} from "./keys";
import {
  flm_full_disk_access,
  flm_host_app,
  fls_footprint_bytes,
  fls_now_ms,
  fls_open,
  fls_process_age_ms,
  fls_read,
  fls_resident_bytes,
  fls_sleep_ms,
  fls_spawn,
  fls_stat,
  fls_tty_enter,
  fls_tty_leave,
  fls_tty_size,
  fls_wall_s,
  fls_write,
} from "./native";
import { absorbBuild, defaultIndexPath, ensureDir, prepareIndex, rebuildIndex } from "./index-file";
import { APP_NAMES_FILE, baseName, dataDir, parentPath } from "./paths";
import { ACTION_COPY, KIND_APP, KIND_FILE, KIND_FOLDER, Row } from "./row";
import { MODE_CLIPBOARD, SearchSession } from "./session";
import { Palette, Screen } from "./screen";
import { listRows, render, Status } from "./view";

const VERSION = "0.2.0";
/** How long a lone ESC waits for the rest of an escape sequence. */
const ESCAPE_WAIT_MS = 25;
const BUILD_POLL_MS = 100;
const US = "\x1f";

const VIEW_SEARCH = 0;
const VIEW_BOARD = 1;

/** floodlight-clipd sits beside this binary unless FLOODLIGHT_CLIPD says otherwise. */
function clipdPath(): string {
  return process.env.FLOODLIGHT_CLIPD ?? parentPath(process.execPath) + "/floodlight-clipd";
}

class Options {
  root = "";
  index = "";
  data = "";
  query = "";
  board = false;
  pastePid = 0;
  /** -2: probe; otherwise the probe result to pretend (tests). */
  fda = -2;
  headless = false;
  exitAfterPaint = false;
  stay = false;
  bench = 0;
  idleReport = 0;
  rows = 0;
  cols = 0;
}

function usage(): string {
  return [
    "usage: floodlight-tui [options]",
    "  --root DIR          folder to index (default: $HOME)",
    "  --index FILE        index file (default: in the data folder)",
    "  --data DIR          data folder: index and clipboard history",
    "  --query TEXT        start with this query",
    "  --board             open the clipboard board",
    "  --paste-pid PID     paste board entries into this process",
    "  --stay              keep running after opening a result",
    "  --fda granted|missing  pretend a Full Disk Access state (tests)",
    "  --headless          read keys from a pipe, no raw mode (tests)",
    "  --size ROWSxCOLS    screen size when there is no terminal",
    "  --exit-after-paint  draw one frame and exit (cold-start timing)",
    "  --idle-report SECS  stay idle, then print memory to stderr and exit",
    "  --bench ROUNDS      time typed-query latency and print JSON",
    "  --version",
  ].join("\n");
}

function parseOptions(args: string[], home: string): Options {
  const o = new Options();
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const value = i + 1 < args.length ? args[i + 1] : "";
    if (arg === "--root") o.root = args[++i];
    else if (arg === "--index") o.index = args[++i];
    else if (arg === "--data") o.data = args[++i];
    else if (arg === "--query") o.query = args[++i];
    else if (arg === "--board") o.board = true;
    else if (arg === "--paste-pid") o.pastePid = parseInt(args[++i], 10);
    else if (arg === "--fda") o.fda = args[++i] === "missing" ? 0 : 1;
    else if (arg === "--stay") o.stay = true;
    else if (arg === "--headless") o.headless = true;
    else if (arg === "--exit-after-paint") o.exitAfterPaint = true;
    else if (arg === "--bench") o.bench = parseInt(args[++i], 10);
    else if (arg === "--idle-report") o.idleReport = parseInt(args[++i], 10);
    else if (arg === "--size") {
      const parts = value.split("x");
      o.rows = parseInt(parts[0], 10);
      o.cols = parseInt(parts[1], 10);
      i++;
    } else if (arg === "--version") {
      console.log("floodlight-tui " + VERSION);
      process.exit(0);
    } else {
      console.error(usage());
      process.exit(arg === "--help" || arg === "-h" ? 0 : 2);
    }
  }
  if (o.root.length === 0) o.root = home;
  if (o.data.length === 0) o.data = dataDir(home);
  if (o.index.length === 0) o.index = o.data.length > 0 ? o.data + "/files.flix" : defaultIndexPath(home);
  return o;
}

function deleteLastWord(text: string): string {
  let end = text.length;
  while (end > 0 && text.charAt(end - 1) === " ") end--;
  while (end > 0 && text.charAt(end - 1) !== " ") end--;
  return text.slice(0, end);
}

function dropLastChar(text: string): string {
  const chars = Array.from(text);
  chars.pop();
  return chars.join("");
}

function mb(bytes: number): string {
  return (bytes / 1048576).toFixed(2);
}

/** Bundle ids Launch Services names badly, from the Swift `ClipboardSourceApp`. */
const KNOWN_APPS = new Map<string, string>([
  ["com.apple.screencaptureui", "Screenshot"],
  ["com.apple.finder", "Finder"],
]);

class NativeFacts extends BoardFacts {
  private readonly names = new Map<string, string>(KNOWN_APPS);
  private namesLoaded = false;
  private readonly statBuf = new Uint8Array(16);
  private readonly statView = new DataView(this.statBuf.buffer);

  constructor(
    private readonly store: SqliteClipStore,
    private readonly data: string,
  ) {
    super();
  }

  /** The names floodlight-clipd resolved when it recorded each entry: the
   * TUI has no AppKit to ask Launch Services itself. */
  private loadNames(): void {
    this.namesLoaded = true;
    let text = "";
    try {
      text = readFileSync(this.data + "/" + APP_NAMES_FILE, "utf8");
    } catch {
      return;
    }
    for (const line of text.split("\n")) {
      const tab = line.indexOf("\t");
      if (tab > 0 && !this.names.has(line.slice(0, tab))) this.names.set(line.slice(0, tab), line.slice(tab + 1));
    }
  }

  appName(bundleId: string): string {
    if (bundleId.length === 0) return "Clipboard";
    if (!this.namesLoaded) this.loadNames();
    const cached = this.names.get(bundleId);
    if (cached !== undefined) return cached;
    const last = bundleId.slice(bundleId.lastIndexOf(".") + 1);
    const name = last.length > 0 ? last.charAt(0).toUpperCase() + last.slice(1) : bundleId;
    this.names.set(bundleId, name);
    return name;
  }

  fullText(entry: ClipEntry): string {
    return entry.truncated ? this.store.fullText(entry.id) : entry.text;
  }

  fileSize(path: string): number {
    const kind = fls_stat(path, this.statBuf);
    if (kind === 0) return -1;
    return kind === 2 ? 0 : this.statView.getFloat64(0, true);
  }
}

class Tui {
  readonly parser = new KeyParser();
  readonly input = new Uint8Array(4096);
  readonly fda = new FdaFlow();
  readonly board: ClipBoard;
  readonly facts: NativeFacts;
  view = VIEW_SEARCH;
  /** The board was the entry point, so leaving it ends the program. */
  boardOnly = false;
  building = false;
  running = true;
  /** floodlight-clipd arguments to run once the TUI has left the terminal:
   * a copy, and for a paste the ⌘V that must land after the popup closes. */
  afterExit = "";
  hostApp = "";
  lastProbeMs = 0;

  constructor(
    readonly o: Options,
    readonly session: SearchSession,
    readonly files: CoreFiles,
    readonly screen: Screen,
    readonly store: SqliteClipStore,
  ) {
    this.board = new ClipBoard(store, () => fls_wall_s());
    this.facts = new NativeFacts(store, o.data);
  }

  status(): Status {
    return new Status(this.files.count(), this.building, this.fda.notice(baseName(this.hostApp)), fls_wall_s());
  }

  frame(): void {
    this.fitScreen();
    if (this.view === VIEW_BOARD) renderBoard(this.screen, this.board, this.facts);
    else render(this.screen, this.session, this.status());
    fls_write(this.screen.flush());
  }

  fitScreen(): void {
    const size = fls_tty_size();
    if (size === 0 || this.o.headless) return;
    this.screen.resize(size >> 16, size & 0xffff);
  }

  openBoard(query: string): void {
    this.view = VIEW_BOARD;
    this.board.filter = 0;
    this.board.setQuery(query);
  }

  /** Applies keys in order. Typing only edits the pending query; it is run
   * once, just before anything that depends on its results. */
  apply(keys: Key[]): void {
    let query = this.session.query;
    const commit = (): void => {
      if (query !== this.session.query) this.session.setQuery(query);
    };
    for (const key of keys) {
      if (!this.running) return;
      if (this.view === VIEW_BOARD) {
        this.applyBoard(key);
        query = this.session.query;
        continue;
      }
      const page = listRows(this.screen.rows);
      if (key.code === KEY_TEXT) query += key.text;
      else if (key.code === KEY_BACKSPACE) {
        if (query.length === 0) {
          this.session.exitMode();
          query = this.session.query;
        } else query = dropLastChar(query);
      } else if (key.code === KEY_CLEAR) query = "";
      else if (key.code === KEY_DELETE_WORD) query = deleteLastWord(query);
      else if (key.code === KEY_QUIT) this.running = false;
      else {
        commit();
        this.applySearchKey(key, page);
        query = this.session.query;
      }
    }
    commit();
  }

  private applySearchKey(key: Key, page: number): void {
    const s = this.session;
    if (key.code === KEY_UP || key.code === KEY_DOWN) s.move(key.code === KEY_UP ? -1 : 1);
    else if (key.code === KEY_PAGE_UP || key.code === KEY_PAGE_DOWN) s.move(key.code === KEY_PAGE_UP ? -page : page);
    else if (key.code === KEY_ENTER || key.code === KEY_REVEAL) this.perform(s.current(), key.code === KEY_REVEAL);
    else if (key.code === KEY_TAB) {
      s.tab();
      if (s.mode === MODE_CLIPBOARD) this.openBoard(s.query);
    } else if (key.code === KEY_SHIFT_TAB) s.exitMode();
    else if (key.code === KEY_ESCAPE) {
      if (!s.exitMode()) this.running = false;
    } else if (key.code === KEY_LEFT || key.code === KEY_RIGHT) this.stepFilter(key.code === KEY_LEFT ? -1 : 1);
    else if (key.code === KEY_ALT && key.text >= "1" && key.text <= "9") {
      const chips = visibleFilters(s.counts, s.filter);
      const at = parseInt(key.text, 10) - 1;
      if (at < chips.length) s.setFilter(chips[at]);
    } else if (key.code === KEY_CTRL && key.text === "y") this.preview(s.current());
    else if (key.code === KEY_CTRL && key.text === "g") this.beginGrant();
    else if (key.code === KEY_CTRL && key.text === "b") {
      s.openClipboard();
      this.openBoard("");
    } else if (key.code === KEY_CTRL && key.text === "d" && s.query.length === 0) this.running = false;
  }

  private stepFilter(delta: number): void {
    const chips = visibleFilters(this.session.counts, this.session.filter);
    const at = chips.indexOf(this.session.filter);
    const next = chips[(at + delta + chips.length) % chips.length];
    if (next < FILTER_COUNT) this.session.setFilter(next);
  }

  private applyBoard(key: Key): void {
    if (key.code === KEY_QUIT) {
      this.running = false;
      return;
    }
    const name = boardKeyName(key);
    if (name.length === 0) return;
    this.runBoard(this.board.handle(name));
  }

  private runBoard(action: BoardAction): void {
    const entry = action.entry;
    if (action.name === "close") this.running = false;
    else if (action.name === "exit") {
      if (this.boardOnly) {
        this.running = false;
        return;
      }
      this.view = VIEW_SEARCH;
      this.session.exitMode();
    } else if (entry !== null && (action.name === "paste" || action.name === "copy")) {
      let args = "--data" + US + this.o.data + US + "--copy" + US + entry.id;
      if (action.name === "paste" && this.o.pastePid > 0) args += US + "--paste-pid" + US + this.o.pastePid;
      this.copy(args);
    } else if (entry !== null && action.name === "reveal") {
      fls_open(entryPath(entry), 1);
    } else if (entry !== null && action.name === "preview") {
      this.previewEntry(entry);
    }
  }

  /** Hands the pasteboard work to floodlight-clipd, after the exit when
   * there is one, so a paste lands in the app the popup covered. */
  private copy(args: string): void {
    if (this.o.stay) {
      fls_spawn(clipdPath() + US + args);
      return;
    }
    this.afterExit = args;
    this.running = false;
  }

  private quickLook(path: string): void {
    if (process.platform === "darwin") fls_spawn("qlmanage" + US + "-p" + US + path);
  }

  private previewEntry(entry: ClipEntry): void {
    const path = entryPath(entry);
    if (path.length > 0) {
      this.quickLook(path);
      return;
    }
    const tmp = (process.env.TMPDIR ?? "/tmp").replace(/\/$/, "");
    if (entry.kind === CLIP_IMAGE) {
      const out = tmp + "/floodlight-preview.png";
      if (this.store.exportImage(entry.id, out)) this.quickLook(out);
      return;
    }
    const out = tmp + "/floodlight-preview.txt";
    writeFileSync(out, this.facts.fullText(entry));
    this.quickLook(out);
  }

  preview(row: Row | null): void {
    if (row !== null && (row.kind === KIND_FILE || row.kind === KIND_FOLDER || row.kind === KIND_APP)) {
      this.quickLook(row.target);
    }
  }

  perform(row: Row | null, reveal: boolean): void {
    if (row === null) return;
    if (row.action === ACTION_COPY) {
      this.copy("--copy-text" + US + row.target);
      return;
    }
    fls_open(
      row.target,
      reveal && (row.kind === KIND_FILE || row.kind === KIND_FOLDER || row.kind === KIND_APP) ? 1 : 0,
    );
    if (!this.o.stay) this.running = false;
  }

  /** Opens System Settings at the list and shows the terminal app in Finder,
   * ready to drag in; the poll then sees the grant. */
  beginGrant(): void {
    if (!this.fda.beginGrant()) return;
    fls_open(FDA_SETTINGS_URL, 0);
    if (this.hostApp.length > 0) fls_open(this.hostApp, 1);
  }

  probeFda(): number {
    return this.o.fda !== -2 ? this.o.fda : flm_full_disk_access();
  }

  /** Reads one batch of keys: blocks for the first byte, then takes
   * everything else already waiting. Null at end of input. */
  readKeys(): Key[] | null {
    let timeout = -1;
    if (this.building) timeout = BUILD_POLL_MS;
    else if (this.fda.polling()) timeout = POLL_MS;
    if (this.parser.hasPendingEscape()) timeout = ESCAPE_WAIT_MS;
    const n = fls_read(this.input, timeout);
    if (n < 0) return null;
    const keys = n === 0 ? this.parser.flushEscape() : this.parser.feed(this.input, n);
    for (;;) {
      const more = fls_read(this.input, 0);
      if (more <= 0) break;
      for (const key of this.parser.feed(this.input, more)) keys.push(key);
    }
    return keys;
  }

  run(): void {
    while (this.running) {
      const keys = this.readKeys();
      if (keys === null) break;
      const before = this.session.generation + this.board.generation + this.view * 1e9;
      const noticeBefore = this.fda.state;
      this.apply(keys);
      if (!this.running) break;
      if (this.building && absorbBuild(this.o.index, this.files)) {
        this.building = false;
        this.session.refresh();
      }
      const now = fls_now_ms();
      if (this.fda.polling() && now - this.lastProbeMs >= POLL_MS) {
        this.lastProbeMs = now;
        if (this.fda.tick(this.probeFda(), fls_wall_s()))
          this.building = rebuildIndex(this.o.index, this.o.root) || this.building;
      }
      const after = this.session.generation + this.board.generation + this.view * 1e9;
      if (after !== before || keys.length === 0 || this.fda.state !== noticeBefore) this.frame();
    }
  }
}

function runBench(o: Options, session: SearchSession, files: CoreFiles, screen: Screen, building: boolean): void {
  if (building) {
    while (!absorbBuild(o.index, files)) fls_sleep_ms(20);
  }
  const words = ["safari", "terminal", "readme", "notes", "config", "swift", "package", "xcode", "makefile", "index"];
  const search: number[] = [];
  const frame: number[] = [];
  const now = fls_wall_s();
  for (let round = 0; round < o.bench; round++) {
    for (const word of words) {
      // Typing one character at a time, the way a user produces queries.
      for (let i = 1; i <= word.length; i++) {
        const t0 = fls_now_ms();
        session.setQuery(word.slice(0, i));
        const t1 = fls_now_ms();
        render(screen, session, new Status(files.count(), false, "", now));
        screen.flush();
        const t2 = fls_now_ms();
        search.push(t1 - t0);
        frame.push(t2 - t0);
      }
    }
  }
  const pct = (xs: number[], p: number): number => {
    const sorted = xs.slice().sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length * p) / 100))];
  };
  const r3 = (x: number): number => Math.round(x * 1000) / 1000;
  console.log(
    JSON.stringify({
      files: files.count(),
      queries: search.length,
      search_p50_ms: r3(pct(search, 50)),
      search_p95_ms: r3(pct(search, 95)),
      keystroke_to_frame_p50_ms: r3(pct(frame, 50)),
      keystroke_to_frame_p95_ms: r3(pct(frame, 95)),
      keystroke_to_frame_max_ms: r3(pct(frame, 100)),
      rss_mb: Number(mb(fls_resident_bytes())),
    }),
  );
}

function main(): void {
  const mainStart = fls_now_ms();
  const home = process.env.HOME ?? "/";
  const o = parseOptions(process.argv.slice(2), home);
  Palette.detect(process.env.COLORTERM ?? "");
  const screen = new Screen(o.rows > 0 ? o.rows : 16, o.cols > 0 ? o.cols : 80);

  const apps = loadApps(applicationFolders(home), home);
  const files = new CoreFiles(o.root, home);
  ensureDir(o.data);
  const building = prepareIndex(o.index, o.root, files);
  const session = new SearchSession(apps, files);

  if (o.bench > 0) {
    runBench(o, session, files, screen, building);
    return;
  }

  if (!o.headless) {
    const tty = fls_tty_enter();
    if (tty <= 0) {
      console.error("floodlight-tui: stdin and stdout must be a terminal (or pass --headless)");
      process.exit(2);
    }
  }

  const store = new SqliteClipStore(o.data + "/clipboard.sqlite");
  const tui = new Tui(o, session, files, screen, store);
  tui.building = building;
  if (o.board) {
    tui.boardOnly = true;
    session.openClipboard();
    tui.openBoard(o.query);
  } else if (o.query.length > 0) {
    session.setQuery(o.query);
  }
  tui.frame();

  const paint = fls_now_ms();
  if (process.env.FLOODLIGHT_TRACE !== undefined || o.exitAfterPaint) {
    console.error(
      JSON.stringify({
        event: "first_paint",
        exec_to_paint_ms: Math.round(fls_process_age_ms() * 1000) / 1000,
        main_to_paint_ms: Math.round((paint - mainStart) * 1000) / 1000,
        apps: apps.length,
        files: files.count(),
        rss_mb: Number(mb(fls_resident_bytes())),
      }),
    );
  }
  if (o.exitAfterPaint) {
    fls_tty_leave();
    return;
  }
  // After the first paint: without Full Disk Access, opening TCC.db waits on
  // tccd, which would spend the whole cold-start budget. The notice can
  // arrive a frame later.
  const hostBuf = new Uint8Array(4096);
  const hostLen = flm_host_app(hostBuf);
  if (hostLen > 0) tui.hostApp = Buffer.from(hostBuf.buffer, 0, hostLen).toString("utf8");
  tui.fda.start(tui.probeFda());
  if (tui.fda.polling() && tui.view === VIEW_SEARCH) tui.frame();
  if (o.idleReport > 0) {
    // Idle the way the launcher idles: parked in poll(), touching nothing.
    fls_sleep_ms(o.idleReport * 1000);
    console.error(
      JSON.stringify({
        event: "idle",
        seconds: o.idleReport,
        rss_mb: Number(mb(fls_resident_bytes())),
        footprint_mb: Number(mb(fls_footprint_bytes())),
      }),
    );
    fls_tty_leave();
    return;
  }
  tui.run();
  fls_tty_leave();
  if (tui.afterExit.length > 0) fls_spawn(clipdPath() + US + tui.afterExit);
}

main();
