/**
 * The language-neutral parity fixtures (fixtures/parity) through this
 * frontend's domain entry points: the Search Session over a real Zig index,
 * the panel's keys, the capture policy and the board. Every frontend runs the
 * same files through its own runner, so "full port" is a test result.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { entrySubtitle } from "../src/domain/board-facts";
import { ClipBoard } from "../src/domain/clip-board";
import { Capture, entryFor, pruneCutoff } from "../src/domain/clip-capture";
import { classify, CLIP_TEXT, ClipEntry, entryBadge, entryTitle } from "../src/domain/clip-entry";
import { MemoryClipStore } from "../src/domain/clip-store";
import { FILTER_ALL, FILTER_APPS, FILTER_FILES, FILTER_FOLDERS, FILTER_IMAGES, FILTER_PDFS } from "../src/domain/filters";
import { formatAge } from "../src/domain/format";
import { handlePanelKey } from "../src/domain/panel";
import { displayPath, parentPath } from "../src/domain/paths";
import { kindName } from "../src/domain/row";
import { App, MODE_CLIPBOARD, MODE_LOCAL, MODE_WEB, SearchSession } from "../src/domain/session";
import { CoreFiles } from "../src/platform/core-files";
import { absorbBuild, rebuildIndex } from "../src/platform/index-file";

const FIXTURES = join(import.meta.dir, "..", "..", "..", "fixtures", "parity");

const FILTERS = new Map<string, number>([
  ["all", FILTER_ALL],
  ["apps", FILTER_APPS],
  ["files", FILTER_FILES],
  ["folders", FILTER_FOLDERS],
  ["pdfs", FILTER_PDFS],
  ["images", FILTER_IMAGES],
]);

// Hand-written JSON; each test reads only the fields it checks.
type Json = any;

function load(name: string): Json {
  return JSON.parse(readFileSync(join(FIXTURES, name), "utf8"));
}

function str(value: unknown): string {
  return value === undefined || value === null ? "" : String(value);
}

function modeName(mode: number): string {
  return mode === MODE_WEB ? "web" : mode === MODE_CLIPBOARD ? "clipboard" : "local";
}

describe("search parity", () => {
  const fx = load("search.json");
  const work = join(tmpdir(), "floodlight-gpuix-parity-" + process.pid);
  const root = join(work, "home");
  const files = new CoreFiles(root, root);
  const apps: App[] = [];

  beforeAll(async () => {
    rmSync(work, { recursive: true, force: true });
    for (const item of fx.tree) {
      const rel = str(item);
      if (rel.endsWith("/")) {
        mkdirSync(join(root, rel), { recursive: true });
      } else {
        mkdirSync(parentPath(join(root, rel)), { recursive: true });
        writeFileSync(join(root, rel), "parity\n");
      }
    }
    const index = join(work, "files.flix");
    expect(rebuildIndex(index, root)).toBe(true);
    for (let i = 0; i < 500 && !absorbBuild(index, files); i++) await Bun.sleep(10);
    expect(files.count()).toBeGreaterThan(0);
    for (const a of fx.apps) {
      const path = join(root, str(a.path));
      apps.push(new App(str(a.name), path, displayPath(parentPath(path), root)));
    }
  });

  afterAll(() => rmSync(work, { recursive: true, force: true }));

  for (const c of fx.cases) {
    const q = str(c.query);
    test("query " + JSON.stringify(q) + (c.filter === undefined ? "" : " filtered to " + str(c.filter)), () => {
      const s = new SearchSession(apps, files);
      s.setQuery(q);
      if (c.filter !== undefined) s.setFilter(FILTERS.get(str(c.filter)) ?? FILTER_ALL);
      const got = s.rows.map((r) => {
        const want = c.rows[s.rows.indexOf(r)] ?? {};
        return {
          kind: kindName(r.kind),
          title: r.title,
          ...(want.detail === undefined ? {} : { detail: r.detail }),
          ...(want.target === undefined ? {} : { target: r.target }),
        };
      });
      const expected = c.rows.map((w: Json) => ({
        kind: str(w.kind),
        title: str(w.title),
        ...(w.detail === undefined ? {} : { detail: str(w.detail) }),
        ...(w.target === undefined ? {} : { target: str(w.target) }),
      }));
      expect(got).toEqual(expected);
      if (c.top_hit !== undefined) expect(s.topHit()?.title ?? "").toBe(str(c.top_hit));
      if (c.counts !== undefined) {
        for (const name of FILTERS.keys()) {
          expect([name, s.counts[FILTERS.get(name) ?? 0]]).toEqual([name, Number(c.counts[name])]);
        }
      }
    });
  }

  for (const m of fx.modes) {
    test("mode: " + str(m.about), () => {
      const s = new SearchSession(apps, files);
      s.setQuery(str(m.query));
      for (const ev of m.events) {
        const e = str(ev);
        if (e === "tab") handlePanelKey(s, "tab", false);
        else if (e.startsWith("type:")) s.setQuery(s.query + e.slice(5));
      }
      expect(modeName(s.mode)).toBe(str(m.mode));
      if (m.engine !== undefined) expect(s.engineId).toBe(str(m.engine));
      expect(s.query).toBe(str(m.field));
      if (m.rows !== undefined) expect(s.rows.map((r) => r.title)).toEqual(m.rows.map(str));
      // The panel's own key path, not the session's: Esc, Shift-Tab or
      // Backspace on an empty field all leave the mode there.
      const exit = str(m.exit);
      if (exit === "backspace") while (s.query.length > 0) s.setQuery(s.query.slice(0, -1));
      handlePanelKey(s, exit, false);
      expect(s.mode).toBe(MODE_LOCAL);
      expect(s.query).toBe(str(m.field_after_exit));
    });
  }
});

describe("clipboard parity", () => {
  const fx = load("clipboard.json");
  const home = str(fx.home);
  const now = Number(fx.now);
  const store = new MemoryClipStore();
  let n = 0;

  for (const c of fx.captures) {
    test("capture " + str(c.name), () => {
      const files: string[] = (c.files ?? []).map(str);
      let text = str(c.text);
      if (c.text_repeat !== undefined) text = str(c.text_repeat.text).repeat(Number(c.text_repeat.times));
      const img = c.image;
      const capture = new Capture(
        c.types.map(str),
        files,
        text,
        img === undefined ? 0 : Number(img.bytes),
        img === undefined ? 0 : Number(img.width),
        img === undefined ? 0 : Number(img.height),
        img === undefined ? "" : str(img.hash),
        "",
      );
      const entry = entryFor(capture, "e" + n++, now, home, store.newest(), store.newestImageHash());
      if (c.expect === "skipped") {
        expect(entry).toBeNull();
        return;
      }
      expect(entry).not.toBeNull();
      if (entry === null) return;
      store.record(entry, capture.imageHash);
      const e = c.expect;
      expect(entry.kind).toBe(str(e.kind));
      if (e.content !== undefined) expect(entryBadge(entry)).toBe(str(e.content));
      if (e.detail !== undefined) expect(entry.contentDetail).toBe(str(e.detail));
      if (e.title !== undefined) expect(entryTitle(entry)).toBe(str(e.title));
      if (e.subtitle !== undefined) expect(entrySubtitle(entry, "", now)).toBe(str(e.subtitle));
    });
  }

  test("ages", () => {
    for (const a of fx.ages) expect(formatAge(now - Number(a.seconds), now)).toBe(str(a.age));
  });

  test("prune keeps pinned and recent entries", () => {
    const pruned = new MemoryClipStore();
    for (const p of fx.prune.entries) {
      const created = now - Number(p.age_days) * 86400;
      pruned.record(
        new ClipEntry(str(p.id), str(p.id), CLIP_TEXT, created, "", p.pinned === true ? created : 0, "plain", ""),
        "",
      );
    }
    pruned.prune(pruneCutoff(now));
    expect(
      pruned
        .list("")
        .map((e) => e.id)
        .sort(),
    ).toEqual(fx.prune.kept.map(str).sort());
  });
});

describe("board parity", () => {
  const fx = load("board.json");
  const now = Number(fx.now);

  function boardStore(): MemoryClipStore {
    const store = new MemoryClipStore();
    for (const e of fx.entries) {
      const text = str(e.text);
      const kind = str(e.kind);
      const c = classify(text, "/Users/me");
      const pinned = e.pinned === undefined ? 0 : now - 100000 + Number(e.pinned);
      store.record(
        new ClipEntry(
          str(e.id),
          text,
          kind,
          now - Number(e.age),
          "",
          pinned,
          kind === CLIP_TEXT ? c.kind : "",
          kind === CLIP_TEXT ? c.detail : "",
          e.width === undefined ? 0 : Number(e.width),
          e.height === undefined ? 0 : Number(e.height),
          100,
        ),
        "",
      );
    }
    return store;
  }

  function freshBoard(): ClipBoard {
    const board = new ClipBoard(boardStore(), () => now);
    board.reload();
    return board;
  }

  test("pinned first, then newest", () => {
    expect(freshBoard().entries.map((e) => e.id)).toEqual(fx.order.map(str));
  });

  for (const c of fx.cases) {
    const keys: string[] = c.keys.map(str);
    test("keys " + keys.join(" "), () => {
      const board = freshBoard();
      let name = "none";
      let entry: ClipEntry | null = null;
      for (const k of keys) {
        const action = board.handle(k);
        name = action.name;
        entry = action.entry;
      }
      expect(name).toBe(str(c.action));
      if (c.entry !== undefined) expect(entry?.id ?? "").toBe(str(c.entry));
      if (c.order_after !== undefined) expect(board.entries.map((e) => e.id)).toEqual(c.order_after.map(str));
      if (c.selected_after !== undefined) expect(board.current()?.id ?? "").toBe(str(c.selected_after));
    });
  }
});
