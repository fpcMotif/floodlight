/**
 * The search session: one query in, one immutable publication of ranked rows
 * out (ADR 0002), plus the mode, filter and selection over it. Pure
 * TypeScript with no native calls, so the TUI, the Cocoa panel and the
 * parity fixtures all run the same code.
 *
 * Local results are ranked in the core's score space: a file hit scores what
 * the Zig core gave it, an app what the ported matcher gives its name plus
 * `APP_BONUS`, so an app beats an equally good file and nothing else. Typed
 * addresses, keyword engines and calculator answers sit above that space, as
 * they do in the Swift app; the web fallback row is always last.
 */
import { convert, evaluate } from "./calculator";
import { queryTerms, scoreAllTerms } from "./core-match";
import {
  addressedRow,
  DEFAULT_ENGINE,
  directLinkRow,
  engineById,
  fallbackRow,
  parseAddress,
  webModeRows,
  engineForKeyword,
} from "./engines";
import { FILTER_ALL, filterCounts, filterIncludes } from "./filters";
import { formatNumber } from "./format";
import { fuzzyMatch } from "./match";
import { ACTION_COPY, ACTION_OPEN, KIND_APP, KIND_CALCULATOR, KIND_FOLDER, Row } from "./row";
import { settingRows } from "./settings";

export { KIND_APP, KIND_FILE, KIND_FOLDER, Row } from "./row";

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

export const APP_BONUS = 60;
export const MAX_ROWS = 80;
/** How many file hits to ask for: some are dropped as app bundle contents. */
const FILE_REQUEST = 120;
const RANK_CALCULATOR = 100000;

export const MODE_LOCAL = 0;
export const MODE_WEB = 1;
export const MODE_CLIPBOARD = 2;

function ranksBefore(a: Row, b: Row): number {
  if (a.score !== b.score) return b.score - a.score;
  if (a.title !== b.title) return a.title < b.title ? -1 : 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

export class SearchSession {
  query = "";
  mode = MODE_LOCAL;
  /** Web mode's engine, and how the mode was entered, so leaving restores the field. */
  engineId = DEFAULT_ENGINE.id;
  typedKeyword = "";
  queryAtEntry = "";
  filter = FILTER_ALL;
  /** Every ranked row of the current query, before the filter. */
  all: Row[] = [];
  /** The rows the filter keeps: what is drawn and what the selection walks. */
  rows: Row[] = [];
  counts: number[] = filterCounts([]);
  selected = 0;
  /** Bumped on every publication, so a renderer can skip unchanged frames. */
  generation = 0;

  constructor(
    private readonly apps: App[],
    private readonly files: FileSource,
  ) {}

  setQuery(query: string): void {
    this.query = query;
    this.publish(this.search(query));
    this.selected = 0;
  }

  /** Re-runs the current query, for when the index under it changed. */
  refresh(): void {
    const keep = this.selected;
    this.publish(this.search(this.query));
    this.selected = Math.min(keep, Math.max(0, this.rows.length - 1));
  }

  setFilter(filter: number): void {
    if (filter === this.filter) return;
    this.filter = filter;
    this.publish(this.all);
    this.selected = 0;
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

  /** The best row, shown apart: the first one, unless it is only the web fallback. */
  topHit(): Row | null {
    if (this.rows.length === 0) return null;
    const first = this.rows[0];
    return first.id === "web-search" ? null : first;
  }

  /** Drops everything a hidden launcher does not need to keep. */
  clear(): void {
    this.mode = MODE_LOCAL;
    this.filter = FILTER_ALL;
    this.setQuery("");
  }

  // ---- modes (the Swift `SearchMode` transitions) ---------------------------

  /** Tab in local mode: `clip …` opens the board, a web keyword its engine,
   * anything else the default engine with the query unchanged. */
  tab(): void {
    if (this.mode !== MODE_LOCAL) return;
    const address = parseAddress(this.query);
    if (address !== null && address.keyword.toLowerCase() === "clip") {
      this.enter(MODE_CLIPBOARD, "", address.keyword, address.remainder);
      return;
    }
    const engine = address === null ? null : engineForKeyword(address.keyword);
    if (engine === null || address === null) {
      this.enter(MODE_WEB, DEFAULT_ENGINE.id, "", this.query);
      return;
    }
    this.enter(MODE_WEB, engine.id, address.keyword, address.remainder);
  }

  /** The global board shortcut: straight into clipboard mode. */
  openClipboard(): void {
    if (this.mode === MODE_CLIPBOARD) return;
    this.enter(MODE_CLIPBOARD, "", "", "");
  }

  /** Shift-Tab, Esc, or Backspace on an empty query. False in local mode,
   * where the key has its own meaning (Esc hides). */
  exitMode(): boolean {
    if (this.mode === MODE_LOCAL) return false;
    let text = this.query;
    if (this.typedKeyword.length > 0) {
      let spelling = this.typedKeyword;
      if (this.query !== this.queryAtEntry) {
        spelling = this.mode === MODE_CLIPBOARD ? "clip" : engineById(this.engineId).keywords[0];
      }
      text = this.query.length === 0 ? spelling : spelling + " " + this.query;
    }
    this.mode = MODE_LOCAL;
    this.typedKeyword = "";
    this.setQuery(text);
    return true;
  }

  private enter(mode: number, engineId: string, keyword: string, query: string): void {
    this.mode = mode;
    if (engineId.length > 0) this.engineId = engineId;
    this.typedKeyword = keyword;
    this.queryAtEntry = query;
    this.filter = FILTER_ALL;
    this.setQuery(query);
  }

  // ---- publication -----------------------------------------------------------

  private publish(all: Row[]): void {
    this.all = all;
    this.counts = filterCounts(all);
    if (this.filter === FILTER_ALL) {
      this.rows = all;
    } else {
      const kept: Row[] = [];
      for (const row of all) if (filterIncludes(this.filter, row)) kept.push(row);
      this.rows = kept;
    }
    this.generation++;
  }

  private search(raw: string): Row[] {
    if (this.mode === MODE_CLIPBOARD) return [];
    const query = raw.trim();
    if (this.mode === MODE_WEB) return query.length === 0 ? [] : webModeRows(query, this.engineId);
    if (query.length === 0) return [];

    const ranked: Row[] = [];
    const link = directLinkRow(query);
    if (link !== null) ranked.push(link);
    const answer = this.calculatorRow(query);
    if (answer !== null) ranked.push(answer);
    const addressed = addressedRow(query);
    if (addressed !== null) ranked.push(addressed);

    const terms = queryTerms(query);
    const appRows = this.searchApps(terms);
    for (const row of appRows) ranked.push(row);
    for (const row of settingRows(terms)) ranked.push(row);
    for (const row of this.files.search(query, FILE_REQUEST)) {
      if (row.target.indexOf(".app/") >= 0) continue;
      if (row.kind === KIND_FOLDER && (row.target.endsWith(".app") || appRows.some((a) => a.target === row.target))) {
        continue;
      }
      ranked.push(row);
    }
    ranked.sort(ranksBefore);
    const rows = ranked.length > MAX_ROWS - 1 ? ranked.slice(0, MAX_ROWS - 1) : ranked;
    rows.push(fallbackRow(query));
    return rows;
  }

  private calculatorRow(query: string): Row | null {
    const value = evaluate(query);
    let answer = "";
    if (!isNaN(value)) {
      answer = formatNumber(value);
    } else {
      const conversion = convert(query);
      if (conversion === null) return null;
      answer = formatNumber(Math.round(conversion.value * 1e6) / 1e6) + " " + conversion.symbol;
    }
    return new Row(
      KIND_CALCULATOR,
      "calculator",
      answer,
      query + " = " + answer + " · Press Return to copy",
      answer,
      ACTION_COPY,
      [],
      RANK_CALCULATOR,
    );
  }

  private searchApps(terms: string[]): Row[] {
    const hits: Row[] = [];
    if (terms.length === 0) return hits;
    const first = terms[0].charAt(0);
    const joined = terms.join("");
    for (const app of this.apps) {
      // Cheap reject before scoring: the first query char must occur.
      if (app.key.indexOf(first) < 0) continue;
      const score = scoreAllTerms(app.name, terms);
      if (score < 0) continue;
      const match = fuzzyMatch(app.name, joined);
      hits.push(
        new Row(
          KIND_APP,
          "app:" + app.path,
          app.name,
          app.detail,
          app.path,
          ACTION_OPEN,
          match === null ? [] : match.positions,
          score + APP_BONUS,
          "app",
        ),
      );
    }
    return hits;
  }
}
