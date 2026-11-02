/**
 * Runs the language-neutral parity fixtures (fixtures/parity at the
 * repository root) through this frontend's domain entry points: the Search
 * Session over a real Zig index, the capture policy, and the board. Every
 * frontend runs the same files through its own runner, so "full port" is a
 * test result (#115).
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { ClipBoard } from "../src/clip-board";
import { Capture, entryFor, pruneCutoff } from "../src/clip-capture";
import { classify, CLIP_TEXT, ClipEntry, entryBadge, entryTitle } from "../src/clip-entry";
import { MemoryClipStore } from "../src/clip-store";
import { entrySubtitle } from "../src/board-view";
import { CoreFiles } from "../src/files";
import { FILTER_ALL, FILTER_APPS, FILTER_FILES, FILTER_FOLDERS, FILTER_IMAGES, FILTER_PDFS } from "../src/filters";
import { formatAge } from "../src/format";
import { absorbBuild, rebuildIndex } from "../src/index-file";
import { fls_sleep_ms } from "../src/native";
import { displayPath, parentPath } from "../src/paths";
import { kindName } from "../src/row";
import { App, MODE_CLIPBOARD, MODE_LOCAL, MODE_WEB, SearchSession } from "../src/session";
import { check, eq, eqn } from "./check";

const FILTERS = new Map<string, number>([
  ["all", FILTER_ALL],
  ["apps", FILTER_APPS],
  ["files", FILTER_FILES],
  ["folders", FILTER_FOLDERS],
  ["pdfs", FILTER_PDFS],
  ["images", FILTER_IMAGES],
]);

function load(path: string): any {
  return JSON.parse(readFileSync(path, "utf8"));
}

function str(value: any): string {
  return value === undefined || value === null ? "" : String(value);
}

function modeName(mode: number): string {
  return mode === MODE_WEB ? "web" : mode === MODE_CLIPBOARD ? "clipboard" : "local";
}

function buildTree(root: string, tree: any): void {
  rmSync(root, { recursive: true, force: true });
  for (const item of tree) {
    const rel = str(item);
    if (rel.endsWith("/")) {
      mkdirSync(root + "/" + rel, { recursive: true });
    } else {
      mkdirSync(parentPath(root + "/" + rel), { recursive: true });
      writeFileSync(root + "/" + rel, "parity\n");
    }
  }
}

function searchParity(dir: string): void {
  const fx = load(dir + "/search.json");
  const work = (process.env.TMPDIR ?? "/tmp") + "/floodlight-parity-" + process.pid;
  const root = work + "/home";
  buildTree(root, fx.tree);
  const index = work + "/files.flix";
  const files = new CoreFiles(root, root);
  check(rebuildIndex(index, root), "parity: index build starts");
  for (let i = 0; i < 500 && !absorbBuild(index, files); i++) fls_sleep_ms(10);
  check(files.count() > 0, "parity: the fixture tree is indexed");

  const apps: App[] = [];
  for (const a of fx.apps) {
    const path = root + "/" + str(a.path);
    apps.push(new App(str(a.name), path, displayPath(parentPath(path), root)));
  }

  for (const c of fx.cases) {
    const s = new SearchSession(apps, files);
    const q = str(c.query);
    s.setQuery(q);
    if (c.filter !== undefined) s.setFilter(FILTERS.get(str(c.filter)) ?? FILTER_ALL);
    const what = "search " + JSON.stringify(q);
    const titles = s.rows.map((r) => r.title).join(" | ");
    eqn(s.rows.length, c.rows.length, what + ": row count (" + titles + ")");
    for (let i = 0; i < c.rows.length && i < s.rows.length; i++) {
      const want = c.rows[i];
      const row = s.rows[i];
      eq(kindName(row.kind) + " " + row.title, str(want.kind) + " " + str(want.title), what + ": row " + i);
      if (want.detail !== undefined) eq(row.detail, str(want.detail), what + ": row " + i + " detail");
      if (want.target !== undefined) eq(row.target, str(want.target), what + ": row " + i + " target");
    }
    if (c.top_hit !== undefined) {
      const top = s.topHit();
      eq(top === null ? "" : top.title, str(c.top_hit), what + ": top hit");
    }
    if (c.counts !== undefined) {
      for (const name of ["all", "apps", "files", "folders", "pdfs", "images"]) {
        eqn(s.counts[FILTERS.get(name) ?? 0], parseInt(str(c.counts[name]), 10), what + ": " + name + " count");
      }
    }
  }

  for (const m of fx.modes) {
    const s = new SearchSession(apps, files);
    s.setQuery(str(m.query));
    const what = "mode " + JSON.stringify(str(m.query));
    for (const ev of m.events) {
      const e = str(ev);
      if (e === "tab") s.tab();
      else if (e.startsWith("type:")) s.setQuery(s.query + e.slice(5));
    }
    eq(modeName(s.mode), str(m.mode), what + ": mode");
    if (m.engine !== undefined) eq(s.engineId, str(m.engine), what + ": engine");
    eq(s.query, str(m.field), what + ": field");
    if (m.rows !== undefined) {
      const want: string[] = [];
      for (const t of m.rows) want.push(str(t));
      eq(s.rows.map((r) => r.title).join("|"), want.join("|"), what + ": rows");
    }
    const exit = str(m.exit);
    if (exit !== "backspace" || s.query.length === 0) s.exitMode();
    eq(modeName(s.mode), "local", what + ": " + exit + " leaves the mode");
    eq(s.query, str(m.field_after_exit), what + ": field after " + exit);
    check(s.mode === MODE_LOCAL, what + ": back in local mode");
  }
  rmSync(work, { recursive: true, force: true });
}

function clipboardParity(dir: string): void {
  const fx = load(dir + "/clipboard.json");
  const home = str(fx.home);
  const now = parseFloat(str(fx.now));
  const store = new MemoryClipStore();
  let n = 0;
  for (const c of fx.captures) {
    const types: string[] = [];
    for (const t of c.types) types.push(str(t));
    const files: string[] = [];
    if (c.files !== undefined) for (const f of c.files) files.push(str(f));
    let text = str(c.text);
    if (c.text_repeat !== undefined) text = str(c.text_repeat.text).repeat(parseInt(str(c.text_repeat.times), 10));
    const img = c.image;
    const capture = new Capture(
      types,
      files,
      text,
      img === undefined ? 0 : parseInt(str(img.bytes), 10),
      img === undefined ? 0 : parseInt(str(img.width), 10),
      img === undefined ? 0 : parseInt(str(img.height), 10),
      img === undefined ? "" : str(img.hash),
      "",
    );
    const entry = entryFor(capture, "e" + n++, now, home, store.newest(), store.newestImageHash());
    const what = "capture " + str(c.name);
    if (c.expect === "skipped") {
      check(entry === null, what + ": skipped");
      continue;
    }
    check(entry !== null, what + ": recorded");
    if (entry === null) continue;
    store.record(entry, capture.imageHash);
    const e = c.expect;
    eq(entry.kind, str(e.kind), what + ": kind");
    if (e.content !== undefined) eq(entryBadge(entry), str(e.content), what + ": content");
    if (e.detail !== undefined) eq(entry.contentDetail, str(e.detail), what + ": detail");
    if (e.title !== undefined) eq(entryTitle(entry), str(e.title), what + ": title");
    if (e.subtitle !== undefined) eq(entrySubtitle(entry, "", now), str(e.subtitle), what + ": subtitle");
  }
  for (const a of fx.ages) {
    eq(formatAge(now - parseFloat(str(a.seconds)), now), str(a.age), "age of " + str(a.seconds) + " s");
  }
  const pruned = new MemoryClipStore();
  for (const p of fx.prune.entries) {
    const created = now - parseFloat(str(p.age_days)) * 86400;
    pruned.record(
      new ClipEntry(str(p.id), str(p.id), CLIP_TEXT, created, "", p.pinned === true ? created : 0, "plain", ""),
      "",
    );
  }
  pruned.prune(pruneCutoff(now));
  const kept: string[] = [];
  for (const k of fx.prune.kept) kept.push(str(k));
  eq(
    pruned
      .list("")
      .map((e) => e.id)
      .sort()
      .join(","),
    kept.sort().join(","),
    "prune keeps pinned and recent entries",
  );
}

function boardStore(fx: any, now: number): MemoryClipStore {
  const store = new MemoryClipStore();
  for (const e of fx.entries) {
    const text = str(e.text);
    const kind = str(e.kind);
    const c = classify(text, "/Users/me");
    const pinned = e.pinned === undefined ? 0 : now - 100000 + parseFloat(str(e.pinned));
    store.record(
      new ClipEntry(
        str(e.id),
        text,
        kind,
        now - parseFloat(str(e.age)),
        "",
        pinned,
        kind === CLIP_TEXT ? c.kind : "",
        kind === CLIP_TEXT ? c.detail : "",
        e.width === undefined ? 0 : parseInt(str(e.width), 10),
        e.height === undefined ? 0 : parseInt(str(e.height), 10),
        100,
      ),
      "",
    );
  }
  return store;
}

function ids(board: ClipBoard): string {
  return board.entries.map((e) => e.id).join(",");
}

function boardParity(dir: string): void {
  const fx = load(dir + "/board.json");
  const now = parseFloat(str(fx.now));
  const order: string[] = [];
  for (const id of fx.order) order.push(str(id));
  const first = new ClipBoard(boardStore(fx, now), () => now);
  first.reload();
  eq(ids(first), order.join(","), "board: pinned first, then newest");

  for (const c of fx.cases) {
    const board = new ClipBoard(boardStore(fx, now), () => now);
    board.reload();
    const keys: string[] = [];
    for (const k of c.keys) keys.push(str(k));
    const what = "board " + keys.join(" ");
    let name = "none";
    let entry: ClipEntry | null = null;
    for (const k of keys) {
      const action = board.handle(k);
      name = action.name;
      entry = action.entry;
    }
    eq(name, str(c.action), what + ": action");
    if (c.entry !== undefined) eq(entry === null ? "" : entry.id, str(c.entry), what + ": entry");
    if (c.order_after !== undefined) {
      const want: string[] = [];
      for (const id of c.order_after) want.push(str(id));
      eq(ids(board), want.join(","), what + ": list after");
    }
    if (c.selected_after !== undefined) {
      const cur = board.current();
      eq(cur === null ? "" : cur.id, str(c.selected_after), what + ": selection after");
    }
  }
}

export function runParity(dir: string): void {
  searchParity(dir);
  clipboardParity(dir);
  boardParity(dir);
}
