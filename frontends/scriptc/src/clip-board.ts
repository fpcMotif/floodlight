/**
 * The clipboard board's state and keys: list, filter, selection, actions
 * menu. Keys arrive as logical names (`return`, `cmd+d`, `option+return`) so
 * the same parity fixture drives every frontend; each frontend maps its own
 * key events onto these names.
 *
 * Pin and delete change the store here. Paste, copy, reveal and preview need
 * the platform, so they come back as the action for the frontend to run.
 */
import { CLIP_FILE, CLIP_IMAGE, CLIP_TEXT, ClipEntry, entryPath } from "./clip-entry";
import { ClipStore } from "./clip-store";

export const BOARD_ALL = 0;
export const BOARD_TEXT = 1;
export const BOARD_FILES = 2;
export const BOARD_IMAGES = 3;
export const BOARD_FILTER_TITLES = ["All", "Text", "Files", "Images"];

export const MENU_PASTE = "paste";
export const MENU_COPY = "copy";
export const MENU_REVEAL = "reveal";
export const MENU_PREVIEW = "preview";
export const MENU_PIN = "pin";
export const MENU_DELETE = "delete";

export class BoardAction {
  constructor(
    /** paste, copy, reveal, preview, actions, pin, unpin, delete, filter,
     * move, type, close, exit, or none. */
    readonly name: string,
    readonly entry: ClipEntry | null,
  ) {}
}

export function boardFilterIncludes(filter: number, entry: ClipEntry): boolean {
  if (filter === BOARD_TEXT) return entry.kind === CLIP_TEXT;
  if (filter === BOARD_FILES) return entry.kind === CLIP_FILE || entryPath(entry).length > 0;
  if (filter === BOARD_IMAGES) return entry.kind === CLIP_IMAGE;
  return true;
}

export class ClipBoard {
  query = "";
  filter = BOARD_ALL;
  entries: ClipEntry[] = [];
  selected = 0;
  menuOpen = false;
  menuSelected = 0;
  generation = 0;
  /** The clock at the last reload, for row ages. */
  now = 0;

  constructor(
    private readonly store: ClipStore,
    private readonly clock: () => number,
  ) {}

  reload(): void {
    this.now = this.clock();
    const listed = this.store.list(this.query);
    const kept: ClipEntry[] = [];
    for (const entry of listed) if (boardFilterIncludes(this.filter, entry)) kept.push(entry);
    const keepId = this.current()?.id ?? "";
    this.entries = kept;
    this.selected = 0;
    for (let i = 0; i < kept.length; i++) if (kept[i].id === keepId) this.selected = i;
    this.generation++;
  }

  setQuery(query: string): void {
    this.query = query;
    this.reload();
    this.selected = 0;
  }

  setFilter(filter: number): void {
    this.filter = filter;
    this.reload();
    this.selected = 0;
  }

  move(delta: number): void {
    if (this.entries.length === 0) return;
    this.selected = Math.max(0, Math.min(this.entries.length - 1, this.selected + delta));
    this.generation++;
  }

  current(): ClipEntry | null {
    return this.selected < this.entries.length ? this.entries[this.selected] : null;
  }

  /** The actions menu for the selection, in display order. */
  menuItems(): string[] {
    const entry = this.current();
    if (entry === null) return [];
    const items = [MENU_PASTE, MENU_COPY];
    if (entryPath(entry).length > 0) items.push(MENU_REVEAL);
    items.push(MENU_PREVIEW, MENU_PIN, MENU_DELETE);
    return items;
  }

  handle(key: string): BoardAction {
    if (this.menuOpen) return this.handleMenu(key);
    const entry = this.current();
    if (key === "up" || key === "down") {
      this.move(key === "up" ? -1 : 1);
      return new BoardAction("move", this.current());
    }
    if (key.startsWith("cmd+") && key.length === 5 && key.charAt(4) >= "1" && key.charAt(4) <= "4") {
      this.setFilter(parseInt(key.charAt(4), 10) - 1);
      return new BoardAction("filter", this.current());
    }
    if (key === "escape") return new BoardAction("close", null);
    if (key === "backspace") {
      if (this.query.length === 0) return new BoardAction("exit", null);
      this.setQuery(Array.from(this.query).slice(0, -1).join(""));
      return new BoardAction("type", this.current());
    }
    if (key.startsWith("text:")) {
      this.setQuery(this.query + key.slice(5));
      return new BoardAction("type", this.current());
    }
    // A space is a preview only while there is no query to type it into.
    if (key === "space") {
      if (this.query.length > 0) {
        this.setQuery(this.query + " ");
        return new BoardAction("type", this.current());
      }
      return this.run(MENU_PREVIEW, entry);
    }
    if (key === "cmd+k") {
      if (entry === null) return new BoardAction("none", null);
      this.menuOpen = true;
      this.menuSelected = 0;
      this.generation++;
      return new BoardAction("actions", entry);
    }
    if (key === "return") return this.run(MENU_PASTE, entry);
    if (key === "option+return" || key === "cmd+c") return this.run(MENU_COPY, entry);
    if (key === "cmd+return" || key === "cmd+r") return this.run(MENU_REVEAL, entry);
    if (key === "cmd+y") return this.run(MENU_PREVIEW, entry);
    if (key === "cmd+.") return this.run(MENU_PIN, entry);
    if (key === "cmd+d") return this.run(MENU_DELETE, entry);
    return new BoardAction("none", null);
  }

  private handleMenu(key: string): BoardAction {
    const items = this.menuItems();
    if (key === "escape" || key === "cmd+k") {
      this.menuOpen = false;
      this.generation++;
      return new BoardAction("none", null);
    }
    if (key === "up" || key === "down") {
      const next = this.menuSelected + (key === "up" ? -1 : 1);
      this.menuSelected = Math.max(0, Math.min(items.length - 1, next));
      this.generation++;
      return new BoardAction("move", this.current());
    }
    if (key === "return" && items.length > 0) {
      this.menuOpen = false;
      this.generation++;
      return this.run(items[this.menuSelected], this.current());
    }
    return new BoardAction("none", null);
  }

  private run(item: string, entry: ClipEntry | null): BoardAction {
    if (entry === null) return new BoardAction("none", null);
    if (item === MENU_REVEAL && entryPath(entry).length === 0) return new BoardAction("none", null);
    if (item === MENU_PIN) {
      const pin = !entry.isPinned();
      this.store.setPinned(entry.id, pin, this.clock());
      this.reload();
      return new BoardAction(pin ? "pin" : "unpin", entry);
    }
    if (item === MENU_DELETE) {
      this.store.remove(entry.id);
      const at = this.selected;
      this.reload();
      this.selected = Math.min(at, Math.max(0, this.entries.length - 1));
      return new BoardAction("delete", entry);
    }
    return new BoardAction(item, entry);
  }
}
