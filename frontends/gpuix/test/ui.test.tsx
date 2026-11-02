/**
 * The React tree on GPUIX's headless renderer (the real GPUI element build,
 * no window): typing reaches the Search Session through the native input, and
 * hiding unmounts every row. Checks what the panel shows, not its structure.
 */
import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createTestRoot, hasNativeTestRenderer } from "@gpuix/react/testing";
import { Controller } from "../src/app/controller";
import { ClipEntry } from "../src/domain/clip-entry";
import { BOARD_HEIGHT, BOARD_WIDTH } from "../src/domain/metrics";
import { App as AppEntry } from "../src/domain/session";
import { SqliteClipStore } from "../src/platform/clip-sqlite";
import { CoreFiles } from "../src/platform/core-files";
import { IconCache } from "../src/platform/icons";
import { App } from "../src/ui/App";
import { ServicesContext } from "../src/ui/context";

const NOW = 1_800_000_000;

function mount() {
  const dir = mkdtempSync(join(tmpdir(), "floodlight-gpuix-ui-"));
  const store = new SqliteClipStore(join(dir, "clipboard.sqlite"));
  const controller = new Controller(
    { home: dir, root: dir, index: join(dir, "files.flix") },
    [
      new AppEntry("Safari", "/Applications/Safari.app", "/Applications"),
      new AppEntry("Notes", "/Applications/Notes.app", "/Applications"),
    ],
    new CoreFiles(dir, dir),
    store,
    () => NOW,
  );
  const t = createTestRoot({ width: BOARD_WIDTH, height: BOARD_HEIGHT });
  t.render(
    <ServicesContext.Provider value={{ controller, icons: new IconCache(dir), imageDir: dir }}>
      <App />
    </ServicesContext.Provider>,
  );
  t.renderer.flush();
  const text = () => {
    t.renderer.flush();
    return t.renderer.getAllText().join(" | ");
  };
  return { controller, store, t, text, done: () => (t.unmount(), rmSync(dir, { recursive: true, force: true })) };
}

describe.skipIf(!hasNativeTestRenderer)("panel on the GPUIX test renderer", () => {
  test("typed keys reach the session and publish rows; hiding removes them", () => {
    const { controller, t, text, done } = mount();
    controller.show("search");
    t.renderer.simulateKeystrokes("s a f");
    expect(controller.session.query).toBe("saf");
    expect(text()).toContain("Safari");
    expect(text()).toContain("APP");
    expect(text()).toContain("Google");

    controller.hide();
    expect(text()).not.toContain("Safari");
    done();
  });

  test("the board lists entries and inspects the selection", () => {
    const { controller, store, text, done } = mount();
    store.record(new ClipEntry("a", "meeting notes for tuesday", "text", NOW - 30, "", 0, "plain", ""), "");
    controller.show("board");
    const shown = text();
    expect(shown).toContain("meeting notes for tuesday");
    expect(shown).toContain("Characters");
    expect(shown).toContain("Paste");
    done();
  });
});
