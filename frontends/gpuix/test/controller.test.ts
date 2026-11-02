/**
 * The controller over the platform stub: what hiding drops, how surfaces
 * switch, and what the board's keys ask for. The stub has no window, so
 * these check the state React draws from, not pixels.
 */
import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Controller } from "../src/app/controller";
import { ClipEntry } from "../src/domain/clip-entry";
import { App } from "../src/domain/session";
import { SqliteClipStore } from "../src/platform/clip-sqlite";
import { CoreFiles } from "../src/platform/core-files";

const NOW = 1_800_000_000;

function make(): { controller: Controller; store: SqliteClipStore; dir: string } {
  const dir = mkdtempSync(join(tmpdir(), "floodlight-gpuix-"));
  const store = new SqliteClipStore(join(dir, "clipboard.sqlite"));
  const controller = new Controller(
    { home: dir, root: dir, index: join(dir, "files.flix") },
    [new App("Safari", "/Applications/Safari.app", "/Applications")],
    new CoreFiles(dir, dir),
    store,
    () => NOW,
  );
  return { controller, store, dir };
}

function text(id: string, body: string, age: number): ClipEntry {
  return new ClipEntry(id, body, "text", NOW - age, "", 0, "plain", "");
}

describe("controller", () => {
  test("hiding drops rows, entries and caches, and leaves an empty search bar", () => {
    const { controller, store, dir } = make();
    store.record(text("a", "alpha", 10), "");
    let released = 0;
    controller.onRelease.push(() => released++);

    controller.show("search");
    controller.setQuery("saf");
    expect(controller.session.rows.length).toBeGreaterThan(0);
    controller.show("board");
    expect(controller.board.entries.map((e) => e.id)).toEqual(["a"]);

    controller.hide();
    expect(controller.surface).toBe("hidden");
    expect(controller.session.query).toBe("");
    expect(controller.session.rows).toEqual([]);
    expect(controller.session.all).toEqual([]);
    expect(controller.board.entries).toEqual([]);
    expect(released).toBe(1);
    rmSync(dir, { recursive: true, force: true });
  });

  test("the hotkeys toggle their own surface and switch between the two", () => {
    const { controller, dir } = make();
    controller.handleEvent(1);
    expect(controller.surface).toBe("search");
    controller.handleEvent(2);
    expect(controller.surface).toBe("board");
    controller.handleEvent(2);
    expect(controller.surface).toBe("hidden");
    rmSync(dir, { recursive: true, force: true });
  });

  test("losing key hides the panel", () => {
    const { controller, dir } = make();
    controller.show("search");
    controller.handleEvent(3);
    expect(controller.surface).toBe("hidden");
    rmSync(dir, { recursive: true, force: true });
  });

  test("board keys: pin, delete, Backspace on empty goes back to search", () => {
    const { controller, store, dir } = make();
    store.record(text("old", "older", 600), "");
    store.record(text("new", "newest", 10), "");
    controller.show("board");
    expect(controller.board.entries.map((e) => e.id)).toEqual(["new", "old"]);

    controller.boardKey("down");
    controller.boardKey("cmd+.");
    expect(controller.board.entries.map((e) => e.id)).toEqual(["old", "new"]);
    controller.boardKey("cmd+d");
    expect(store.list("").map((e) => e.id)).toEqual(["new"]);

    controller.boardKey("backspace");
    expect(controller.surface).toBe("search");
    rmSync(dir, { recursive: true, force: true });
  });

  test("typing filters the board through the store's full-text search", () => {
    const { controller, store, dir } = make();
    store.record(text("a", "meeting notes", 30), "");
    store.record(text("b", "grocery list", 20), "");
    controller.show("board");
    controller.boardQuery("notes");
    expect(controller.board.entries.map((e) => e.id)).toEqual(["a"]);
    rmSync(dir, { recursive: true, force: true });
  });
});
