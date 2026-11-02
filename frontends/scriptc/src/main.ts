/**
 * floodlight-tui: Floodlight's launcher as a terminal program.
 *
 * One thread, one blocking loop: wait for input, apply every key that has
 * arrived, run the query once for the newest text, draw the difference. A
 * burst of typing therefore costs one search, not one per key — latest wins
 * without any cancellation machinery, because nothing runs concurrently.
 * The only other thread is the index rebuild inside the C shim.
 */
import { applicationFolders, loadApps } from "./apps";
import { CoreFiles } from "./files";
import {
  KEY_BACKSPACE,
  KEY_CLEAR,
  KEY_DELETE_WORD,
  KEY_DOWN,
  KEY_ENTER,
  KEY_ESCAPE,
  KEY_PAGE_DOWN,
  KEY_PAGE_UP,
  KEY_QUIT,
  KEY_REVEAL,
  KEY_TEXT,
  KEY_UP,
  Key,
  KeyParser,
} from "./keys";
import {
  fls_footprint_bytes,
  fls_now_ms,
  fls_open,
  fls_process_age_ms,
  fls_read,
  fls_resident_bytes,
  fls_sleep_ms,
  fls_tty_enter,
  fls_tty_leave,
  fls_tty_size,
  fls_write,
} from "./native";
import { absorbBuild, defaultIndexPath, prepareIndex } from "./index-file";
import { SearchSession } from "./session";
import { Screen } from "./screen";
import { listRows, render, Status } from "./view";

const VERSION = "0.1.0";
/** How long a lone ESC waits for the rest of an escape sequence. */
const ESCAPE_WAIT_MS = 25;
const BUILD_POLL_MS = 100;

class Options {
  root = "";
  index = "";
  query = "";
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
    "  --index FILE        index file (default: the user cache folder)",
    "  --query TEXT        start with this query",
    "  --stay              keep running after opening a result",
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
    else if (arg === "--query") o.query = args[++i];
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
  if (o.index.length === 0) o.index = defaultIndexPath(home);
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

class App {
  readonly parser = new KeyParser();
  readonly input = new Uint8Array(4096);
  building = false;
  running = true;

  constructor(
    readonly o: Options,
    readonly session: SearchSession,
    readonly files: CoreFiles,
    readonly screen: Screen,
  ) {}

  status(): Status {
    return new Status(this.files.count(), this.building);
  }

  frame(): void {
    this.fitScreen();
    render(this.screen, this.session, this.status());
    fls_write(this.screen.flush());
  }

  fitScreen(): void {
    const size = fls_tty_size();
    if (size === 0 || this.o.headless) return;
    this.screen.resize(size >> 16, size & 0xffff);
  }

  /** Applies keys in order. Typing only edits the pending query; it is run
   * once, just before anything that depends on its results. */
  apply(keys: Key[]): void {
    let query = this.session.query;
    const commit = (): void => {
      if (query !== this.session.query) this.session.setQuery(query);
    };
    for (const key of keys) {
      const page = listRows(this.screen.rows);
      if (key.code === KEY_TEXT) query += key.text;
      else if (key.code === KEY_BACKSPACE) query = dropLastChar(query);
      else if (key.code === KEY_CLEAR) query = "";
      else if (key.code === KEY_DELETE_WORD) query = deleteLastWord(query);
      else if (key.code === KEY_UP || key.code === KEY_DOWN) {
        commit();
        this.session.move(key.code === KEY_UP ? -1 : 1);
      } else if (key.code === KEY_PAGE_UP || key.code === KEY_PAGE_DOWN) {
        commit();
        this.session.move(key.code === KEY_PAGE_UP ? -page : page);
      } else if (key.code === KEY_ENTER || key.code === KEY_REVEAL) {
        commit();
        this.openSelection(key.code === KEY_REVEAL);
      } else if (key.code === KEY_ESCAPE || key.code === KEY_QUIT) {
        this.running = false;
      }
      if (!this.running) return;
    }
    commit();
  }

  openSelection(reveal: boolean): void {
    const row = this.session.current();
    if (row === null) return;
    fls_open(row.path, reveal ? 1 : 0);
    if (!this.o.stay) this.running = false;
  }

  /** Reads one batch of keys: blocks for the first byte, then takes
   * everything else already waiting. -1 at end of input. */
  readKeys(): Key[] | null {
    let timeout = this.building ? BUILD_POLL_MS : -1;
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
      const before = this.session.generation;
      this.apply(keys);
      if (!this.running) break;
      if (this.building && absorbBuild(this.o.index, this.files)) {
        this.building = false;
        this.session.refresh();
      }
      if (this.session.generation !== before || keys.length === 0) this.frame();
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
  for (let round = 0; round < o.bench; round++) {
    for (const word of words) {
      // Typing one character at a time, the way a user produces queries.
      for (let i = 1; i <= word.length; i++) {
        const t0 = fls_now_ms();
        session.setQuery(word.slice(0, i));
        const t1 = fls_now_ms();
        render(screen, session, new Status(files.count(), false));
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
  const screen = new Screen(o.rows > 0 ? o.rows : 16, o.cols > 0 ? o.cols : 80);

  const apps = loadApps(applicationFolders(home), home);
  const files = new CoreFiles(o.root, home);
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

  const app = new App(o, session, files, screen);
  app.building = building;
  if (o.query.length > 0) session.setQuery(o.query);
  app.frame();

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
  app.run();
  fls_tty_leave();
}

main();
