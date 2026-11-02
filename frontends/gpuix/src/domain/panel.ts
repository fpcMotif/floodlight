/**
 * The search panel's keys, as logical names (`return`, `cmd+return`,
 * `shift+tab`), and the action each asks the platform for. Pure: the React
 * panel maps GPUI key events onto these names with `keyName`, and the tests
 * feed the names directly.
 */
import { FILTER_COUNT } from "./filters";
import { ACTION_COPY, KIND_APP, KIND_CALCULATOR, KIND_FILE, KIND_FOLDER, Row } from "./row";
import { MODE_CLIPBOARD, MODE_LOCAL, SearchSession } from "./session";

/** What a key asks the frontend to do; the session already holds any state change. */
export class PanelAction {
  constructor(
    /** open, copy, reveal, preview, hide, board, grant, move, filter, mode, or none. */
    readonly name: string,
    readonly row: Row | null,
  ) {}
}

const NONE = new PanelAction("none", null);

/** The modifier and key of one GPUI key event. */
export interface KeyStroke {
  key?: string;
  modifiers?: { shift: boolean; ctrl: boolean; alt: boolean; cmd: boolean };
}

/**
 * `cmd+shift+return` style names, the spelling the parity fixtures use. GPUI
 * says `enter` and `alt`; the fixtures say `return` and `option`, as the
 * Swift key equivalents do.
 */
export function keyName(stroke: KeyStroke): string {
  const raw = stroke.key ?? "";
  const key = raw === "enter" ? "return" : raw;
  const m = stroke.modifiers;
  if (m === undefined) return key;
  let prefix = "";
  if (m.cmd) prefix += "cmd+";
  if (m.ctrl) prefix += "ctrl+";
  if (m.alt) prefix += "option+";
  if (m.shift) prefix += "shift+";
  return prefix + key;
}

function hasPath(row: Row | null): boolean {
  return row !== null && (row.kind === KIND_FILE || row.kind === KIND_FOLDER || row.kind === KIND_APP);
}

/** The action for `key` in the search panel; `fdaMissing` enables ⌘G. */
export function handlePanelKey(session: SearchSession, key: string, fdaMissing: boolean): PanelAction {
  const row = session.current();
  if (key === "up" || key === "down") {
    session.move(key === "up" ? -1 : 1);
    return new PanelAction("move", session.current());
  }
  if (key === "return") {
    if (row === null) return NONE;
    return new PanelAction(row.action === ACTION_COPY || row.kind === KIND_CALCULATOR ? "copy" : "open", row);
  }
  if (key === "cmd+return") return hasPath(row) ? new PanelAction("reveal", row) : NONE;
  if (key === "cmd+y" || (key === "space" && session.query.length === 0)) {
    return hasPath(row) ? new PanelAction("preview", row) : NONE;
  }
  if (key === "escape") return session.exitMode() ? new PanelAction("mode", null) : new PanelAction("hide", null);
  if (key === "shift+tab") return session.exitMode() ? new PanelAction("mode", null) : NONE;
  if (key === "backspace" && session.query.length === 0) {
    return session.exitMode() ? new PanelAction("mode", null) : NONE;
  }
  if (key === "tab") {
    if (session.mode !== MODE_LOCAL) return NONE;
    session.tab();
    const entered: number = session.mode;
    return new PanelAction(entered === MODE_CLIPBOARD ? "board" : "mode", null);
  }
  if (key === "cmd+g" && fdaMissing) return new PanelAction("grant", null);
  if (key.startsWith("cmd+") && key.length === 5) {
    const n = key.charCodeAt(4) - 49;
    if (n >= 0 && n < FILTER_COUNT) {
      session.setFilter(n);
      return new PanelAction("filter", session.current());
    }
  }
  return NONE;
}
