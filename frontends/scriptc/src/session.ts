/**
 * The search session: one query in, one ranked list of rows out, plus the
 * selection over it. Pure TypeScript with no native calls, so the same module
 * runs in the compiled frontend and in the self-test.
 *
 * Mirrors the shape of the Swift app's SearchSession → ResultPublication
 * (ADR 0001, 0002) at the scale this frontend needs: applications first, the
 * way Spotlight's top hits read, then files from the core index.
 */
import { fuzzyMatch } from "./match";

export const KIND_APP = 0;
export const KIND_FOLDER = 1;
export const KIND_FILE = 2;

export class Row {
  constructor(
    readonly kind: number,
    readonly title: string,
    /** Where it lives, already abbreviated for display. */
    readonly detail: string,
    /** Absolute path handed to `open`. */
    readonly path: string,
    /** Highlighted UTF-16 offsets in `title`. */
    readonly marks: number[],
    readonly score: number,
  ) {}
}

export class App {
  /** Lowercased once at load, not once per keystroke. */
  readonly key: string;
  constructor(
    readonly name: string,
    readonly path: string,
    readonly detail: string,
  ) {
    this.key = name.toLowerCase();
  }
}

/**
 * The seam to the file index; the self-test passes a fake. A base class, not
 * an interface: scriptc dispatches class methods natively, while a call
 * through an interface falls back to its dynamic tier.
 */
export abstract class FileSource {
  abstract search(query: string, limit: number): Row[];
  abstract count(): number;
}

export const MAX_APPS = 6;
export const MAX_ROWS = 40;

export class SearchSession {
  query = "";
  rows: Row[] = [];
  selected = 0;
  /** Bumped on every publication, so a renderer can skip unchanged frames. */
  generation = 0;

  constructor(
    private readonly apps: App[],
    private readonly files: FileSource,
  ) {}

  setQuery(query: string): void {
    this.query = query;
    this.rows = this.search(query);
    this.selected = 0;
    this.generation++;
  }

  /** Re-runs the current query, for when the index under it changed. */
  refresh(): void {
    const keep = this.selected;
    this.rows = this.search(this.query);
    this.selected = Math.min(keep, Math.max(0, this.rows.length - 1));
    this.generation++;
  }

  move(delta: number): void {
    if (this.rows.length === 0) return;
    const next = Math.max(0, Math.min(this.rows.length - 1, this.selected + delta));
    if (next === this.selected) return;
    this.selected = next;
    this.generation++;
  }

  current(): Row | null {
    return this.selected < this.rows.length ? this.rows[this.selected] : null;
  }

  /** Drops everything a hidden launcher does not need to keep. */
  clear(): void {
    this.setQuery("");
  }

  private search(raw: string): Row[] {
    const query = raw.trim();
    if (query.length === 0) return [];
    const appRows = this.searchApps(query.toLowerCase().split(" ").join(""));
    const fileRows = this.files.search(query, MAX_ROWS - appRows.length);
    const rows: Row[] = [];
    for (const row of appRows) rows.push(row);
    for (const row of fileRows) {
      // An app bundle can also surface as a folder hit; show it once.
      if (!appRows.some((app) => app.path === row.path)) rows.push(row);
    }
    return rows;
  }

  private searchApps(query: string): Row[] {
    const hits: Row[] = [];
    for (const app of this.apps) {
      // Cheap reject before scoring: the first query char must occur.
      if (app.key.indexOf(query.charAt(0)) < 0) continue;
      const match = fuzzyMatch(app.name, query);
      if (match === null) continue;
      hits.push(new Row(KIND_APP, app.name, app.detail, app.path, match.positions, match.score));
    }
    hits.sort((a, b) => b.score - a.score || a.title.length - b.title.length);
    return hits.length > MAX_APPS ? hits.slice(0, MAX_APPS) : hits;
  }
}
