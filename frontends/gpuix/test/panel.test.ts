/** The search panel's keys and the row text, through the domain entry points. */
import { describe, expect, test } from "bun:test";
import { FILTER_FILES } from "../src/domain/filters";
import { EXPANDED_HEIGHT, panelSize, SEARCH_HEIGHT, BOARD_HEIGHT, BOARD_WIDTH } from "../src/domain/metrics";
import { handlePanelKey, keyName } from "../src/domain/panel";
import { ACTION_OPEN, KIND_FILE, KIND_FOLDER, Row } from "../src/domain/row";
import { rowBadge, rowSubtitle, windowTop } from "../src/domain/row-text";
import { App, FileSource, MODE_CLIPBOARD, MODE_LOCAL, MODE_WEB, SearchSession } from "../src/domain/session";

class FakeFiles extends FileSource {
  constructor(private readonly rows: Row[]) {
    super();
  }
  search(): Row[] {
    return this.rows;
  }
  count(): number {
    return this.rows.length;
  }
}

function file(title: string, score: number, kind = KIND_FILE): Row {
  const path = "/Users/me/Documents/" + title;
  const ext = kind === KIND_FILE ? title.slice(title.lastIndexOf(".") + 1) : "";
  return new Row(kind, "file:" + path, title, "~/Documents", path, ACTION_OPEN, [], score, ext, 12000, 0);
}

function session(): SearchSession {
  const files = new FakeFiles([file("report.pdf", 200), file("reports", 150, KIND_FOLDER)]);
  return new SearchSession([new App("Reporter", "/Applications/Reporter.app", "/Applications")], files);
}

describe("panel keys", () => {
  test("GPUI key events become fixture key names", () => {
    const none = { shift: false, ctrl: false, alt: false, cmd: false };
    expect(keyName({ key: "enter", modifiers: none })).toBe("return");
    expect(keyName({ key: "enter", modifiers: { ...none, cmd: true } })).toBe("cmd+return");
    expect(keyName({ key: "tab", modifiers: { ...none, shift: true } })).toBe("shift+tab");
    expect(keyName({ key: "return", modifiers: { ...none, alt: true } })).toBe("option+return");
  });

  test("Return opens the selection, ⌘Return reveals it, arrows move", () => {
    const s = session();
    s.setQuery("rep");
    expect(handlePanelKey(s, "return", false).name).toBe("open");
    expect(handlePanelKey(s, "down", false).row?.title).toBe(s.rows[1].title);
    const reveal = handlePanelKey(s, "cmd+return", false);
    expect(reveal.name).toBe("reveal");
    expect(reveal.row?.title).toBe(s.rows[1].title);
  });

  test("a calculator answer is copied, not opened", () => {
    const s = session();
    s.setQuery("2*(3+4)");
    const action = handlePanelKey(s, "return", false);
    expect(action.name).toBe("copy");
    expect(action.row?.target).toBe("14");
  });

  test("Esc leaves web mode first, then hides", () => {
    const s = session();
    s.setQuery("rep");
    expect(handlePanelKey(s, "tab", false).name).toBe("mode");
    expect(s.mode).toBe(MODE_WEB);
    expect(handlePanelKey(s, "escape", false).name).toBe("mode");
    expect(s.mode).toBe(MODE_LOCAL);
    expect(handlePanelKey(s, "escape", false).name).toBe("hide");
  });

  test("Tab on `clip` opens the board", () => {
    const s = session();
    s.setQuery("clip notes");
    expect(handlePanelKey(s, "tab", false).name).toBe("board");
    expect(s.mode).toBe(MODE_CLIPBOARD);
  });

  test("⌘3 picks the Files chip; ⌘G grants only while access is missing", () => {
    const s = session();
    s.setQuery("rep");
    expect(handlePanelKey(s, "cmd+3", false).name).toBe("filter");
    expect(s.filter).toBe(FILTER_FILES);
    expect(s.rows.map((r) => r.title)).toEqual(["report.pdf"]);
    expect(handlePanelKey(s, "cmd+g", false).name).toBe("none");
    expect(handlePanelKey(s, "cmd+g", true).name).toBe("grant");
  });

  test("⌘Y previews files but not web rows", () => {
    const s = session();
    s.setQuery("rep");
    expect(handlePanelKey(s, "cmd+y", false).name).toBe("preview");
    s.selected = s.rows.length - 1;
    expect(handlePanelKey(s, "cmd+y", false).name).toBe("none");
  });
});

describe("row text and geometry", () => {
  test("badges and subtitles", () => {
    const pdf = file("report.pdf", 1);
    expect(rowBadge(pdf)).toBe("PDF");
    expect(rowSubtitle(pdf, 0)).toBe("~/Documents · 12 KB");
    expect(rowBadge(file("reports", 1, KIND_FOLDER))).toBe("FOLDER");
  });

  test("the row window keeps the selection in view and moves as little as it can", () => {
    expect(windowTop(0, 3, 7, 80)).toBe(0);
    expect(windowTop(0, 7, 7, 80)).toBe(1);
    expect(windowTop(5, 4, 7, 80)).toBe(4);
    expect(windowTop(70, 79, 7, 80)).toBe(73);
    expect(windowTop(10, 2, 7, 5)).toBe(0);
  });

  test("two panel heights, as in Swift, and the 840 × 560 board", () => {
    expect(panelSize(false, false, false).height).toBe(SEARCH_HEIGHT);
    expect(panelSize(true, false, false).height).toBe(EXPANDED_HEIGHT);
    expect([BOARD_WIDTH, BOARD_HEIGHT]).toEqual([840, 560]);
    expect(panelSize(true, true, false)).toEqual(panelSize(false, true, true));
  });
});
