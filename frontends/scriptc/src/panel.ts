/**
 * floodlight-panel: the same search session as floodlight-tui, shown in a
 * native floating panel (#111) drawn by AppKit through native/flpanel.m.
 *
 * The process idles in the background with no window and no rows. ⌥Space
 * (a Carbon hotkey) shows the panel; Esc, Enter, or a click elsewhere hides
 * it and drops the results and icons again, so idle memory is the baseline.
 */
import { applicationFolders, loadApps } from "./apps";
import { CoreFiles } from "./files";
import { absorbBuild, defaultIndexPath, prepareIndex } from "./index-file";
import {
  fls_footprint_bytes,
  fls_now_ms,
  fls_open,
  fls_process_age_ms,
  fls_resident_bytes,
  fls_sleep_ms,
} from "./native";
import {
  flp_add_row,
  flp_clear_rows,
  flp_commit,
  flp_event_arg,
  flp_hide,
  flp_query,
  flp_select,
  flp_show,
  flp_start,
  flp_wait,
} from "./panel-native";
import { SearchSession } from "./session";

const EV_NONE = 0;
const EV_QUERY = 1;
const EV_UP = 2;
const EV_DOWN = 3;
const EV_ENTER = 4;
const EV_REVEAL = 5;
const EV_ESCAPE = 6;
const EV_HOTKEY = 7;
const EV_HIDDEN = 8;
const EV_SELECT_INDEX = 9;
const EV_OPEN_INDEX = 10;

const BUILD_POLL_MS = 100;

class Options {
  root = "";
  index = "";
  hotkey = true;
  smoke = "";
  idle = 0;
  show = false;
}

function parseOptions(args: string[], home: string): Options {
  const o = new Options();
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--root") o.root = args[++i];
    else if (arg === "--index") o.index = args[++i];
    else if (arg === "--no-hotkey") o.hotkey = false;
    else if (arg === "--show") o.show = true;
    else if (arg === "--smoke") o.smoke = args[++i];
    else if (arg === "--idle") o.idle = parseInt(args[++i], 10);
    else {
      console.error(
        [
          "usage: floodlight-panel [options]",
          "  --root DIR      folder to index (default: $HOME)",
          "  --index FILE    index file (default: the user cache folder)",
          "  --show          show the panel at launch",
          "  --no-hotkey     do not register ⌥Space",
          "  --smoke QUERY   show, search QUERY, report timings as JSON, hide",
          "  --idle SECS     with --smoke: then idle and report memory",
        ].join("\n"),
      );
      process.exit(arg === "--help" || arg === "-h" ? 0 : 2);
    }
  }
  if (o.root.length === 0) o.root = home;
  if (o.index.length === 0) o.index = defaultIndexPath(home);
  return o;
}

const r3 = (x: number): number => Math.round(x * 1000) / 1000;
const mb = (bytes: number): number => Math.round((bytes / 1048576) * 100) / 100;

class Panel {
  private readonly queryBuf = new Uint8Array(4096);
  building = false;
  visible = false;

  constructor(
    readonly o: Options,
    readonly session: SearchSession,
    readonly files: CoreFiles,
  ) {}

  /** Sends the whole result list; called only when the query changed. */
  publish(): void {
    flp_clear_rows();
    for (const row of this.session.rows) {
      flp_add_row(row.kind, row.title, row.detail, row.path, row.marks.join(","));
    }
    flp_commit(this.session.selected);
  }

  show(): number {
    this.visible = true;
    return flp_show();
  }

  hide(): void {
    this.visible = false;
    flp_hide();
    this.session.clear();
  }

  readQuery(): string {
    const len = flp_query(this.queryBuf);
    return Buffer.from(this.queryBuf.buffer, 0, len).toString("utf8");
  }

  open(reveal: boolean): void {
    const row = this.session.current();
    if (row === null) return;
    this.hide();
    fls_open(row.path, reveal ? 1 : 0);
  }

  handle(event: number): void {
    if (event === EV_QUERY) {
      this.session.setQuery(this.readQuery());
      this.publish();
    } else if (event === EV_UP || event === EV_DOWN) {
      this.session.move(event === EV_UP ? -1 : 1);
      flp_select(this.session.selected);
    } else if (event === EV_SELECT_INDEX || event === EV_OPEN_INDEX) {
      this.session.move(flp_event_arg() - this.session.selected);
      flp_select(this.session.selected);
      if (event === EV_OPEN_INDEX) this.open(false);
    } else if (event === EV_ENTER || event === EV_REVEAL) {
      this.open(event === EV_REVEAL);
    } else if (event === EV_ESCAPE || event === EV_HIDDEN) {
      if (this.visible) this.hide();
    } else if (event === EV_HOTKEY) {
      if (this.visible) this.hide();
      else this.show();
    }
  }

  run(): void {
    for (;;) {
      const event = flp_wait(this.building ? BUILD_POLL_MS : -1);
      if (event !== EV_NONE) this.handle(event);
      if (this.building && absorbBuild(this.o.index, this.files)) {
        this.building = false;
        if (this.visible) {
          this.session.refresh();
          this.publish();
        }
      }
    }
  }
}

/** Show, type, draw, hide, idle: the numbers the PR reports for #111. */
function smoke(panel: Panel, query: string, idleSeconds: number): void {
  if (panel.building) {
    while (!absorbBuild(panel.o.index, panel.files)) fls_sleep_ms(20);
    panel.building = false;
  }
  const showMs = panel.show();
  const firstFrame = fls_process_age_ms();
  const t0 = fls_now_ms();
  panel.session.setQuery(query);
  panel.publish();
  const queryMs = fls_now_ms() - t0;
  const rows = panel.session.rows.length;
  const visibleRss = fls_resident_bytes();
  panel.hide();
  flp_wait(0);
  console.log(
    JSON.stringify({
      event: "panel_smoke",
      exec_to_visible_ms: r3(firstFrame),
      show_ms: r3(showMs),
      query_to_rows_ms: r3(queryMs),
      rows: rows,
      files: panel.files.count(),
      visible_rss_mb: mb(visibleRss),
    }),
  );
  if (idleSeconds > 0) {
    // Parked the way the background process parks between summons.
    fls_sleep_ms(idleSeconds * 1000);
    console.log(
      JSON.stringify({
        event: "panel_idle",
        seconds: idleSeconds,
        rss_mb: mb(fls_resident_bytes()),
        footprint_mb: mb(fls_footprint_bytes()),
      }),
    );
  }
}

function main(): void {
  const home = process.env.HOME ?? "/";
  const o = parseOptions(process.argv.slice(2), home);
  const files = new CoreFiles(o.root, home);
  const session = new SearchSession(loadApps(applicationFolders(home), home), files);
  const panel = new Panel(o, session, files);
  panel.building = prepareIndex(o.index, o.root, files);

  const started = flp_start(o.hotkey && o.smoke.length === 0 ? 1 : 0);
  if (started < 0) {
    console.error(
      started === -1
        ? "floodlight-panel: AppKit needs the main thread"
        : "floodlight-panel: ⌥Space is taken by another app (pass --no-hotkey)",
    );
    process.exit(1);
  }
  if (o.smoke.length > 0) {
    smoke(panel, o.smoke, o.idle);
    return;
  }
  if (o.show) panel.show();
  panel.run();
}

main();
