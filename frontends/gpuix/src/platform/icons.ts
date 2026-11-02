/**
 * Icons as small PNG files on disk, drawn once by NSWorkspace. GPUI loads an
 * `<img>` path on a background task, so neither the bytes nor a data URL
 * ever sit on the JS heap. Files share one icon per extension; apps and
 * folders get their own.
 */
import { KIND_APP, KIND_FILE, KIND_FOLDER, Row } from "../domain/row";
import { iconFile } from "./native";

/** Pixels: the 46 pt Top Hit tile at 2x. */
const ICON_PIXELS = 96;

function hash(text: string): string {
  return Bun.hash(text).toString(36);
}

export class IconCache {
  /** Key → file path, or "" when no icon could be drawn. Cleared on hide. */
  private paths = new Map<string, string>();

  constructor(private readonly dir: string) {}

  private keyFor(row: Row): string {
    if (row.kind === KIND_FILE) return "ext-" + (row.ext.length > 0 ? row.ext : "none");
    if (row.kind === KIND_FOLDER) return row.target.endsWith(".app") ? "app-" + hash(row.target) : "folder";
    if (row.kind === KIND_APP) return "app-" + hash(row.target);
    return "";
  }

  /** A path for `<img src>`, or "" for rows drawn with a glyph instead. */
  forRow(row: Row): string {
    const key = this.keyFor(row);
    if (key.length === 0) return "";
    const known = this.paths.get(key);
    if (known !== undefined) return known;
    const path = this.dir + "/" + key + ".png";
    const made = iconFile(row.target, path, ICON_PIXELS) ? path : "";
    this.paths.set(key, made);
    return made;
  }

  forPath(path: string): string {
    const key = "path-" + hash(path);
    const known = this.paths.get(key);
    if (known !== undefined) return known;
    const out = this.dir + "/" + key + ".png";
    const made = iconFile(path, out, ICON_PIXELS) ? out : "";
    this.paths.set(key, made);
    return made;
  }

  clear(): void {
    this.paths = new Map();
  }
}
