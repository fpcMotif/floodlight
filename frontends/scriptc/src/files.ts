/** File search through floodlight-core, the Zig index (ADR 0010). */
import { fls_is_dir, fls_path, fls_search, fls_stat } from "./native";
import { fuzzyMatch } from "./match";
import { baseName, displayPath, joinPath, parentPath } from "./paths";
import { ACTION_OPEN, extensionOf, KIND_FILE, KIND_FOLDER, Row } from "./row";
import { FileSource } from "./session";

/** fl_hit is a u32 id and an i32 score. */
const HIT_BYTES = 8;
/** The core caps one search at 256 hits. */
const MAX_HITS = 256;

/** The term worth highlighting: the longest one that names a file, not a path. */
function highlightTerm(query: string): string {
  let best = "";
  for (const term of query.toLowerCase().split(" ")) {
    const name = term.slice(term.lastIndexOf("/") + 1);
    if (name.length > best.length) best = name;
  }
  return best;
}

export class CoreFiles extends FileSource {
  private readonly hits = new Uint8Array(MAX_HITS * HIT_BYTES);
  private readonly view = new DataView(this.hits.buffer);
  private readonly pathBuf = new Uint8Array(4096);
  private readonly statBuf = new Uint8Array(16);
  private readonly statView = new DataView(this.statBuf.buffer);
  entries = -1;

  constructor(
    private readonly root: string,
    private readonly home: string,
  ) {
    super();
  }

  count(): number {
    return this.entries;
  }

  search(query: string, limit: number): Row[] {
    if (this.entries <= 0 || limit <= 0) return [];
    const want = Math.min(limit, MAX_HITS);
    const n = fls_search(query, this.hits.subarray(0, want * HIT_BYTES));
    const term = highlightTerm(query);
    const rows: Row[] = [];
    for (let i = 0; i < n; i++) {
      const id = this.view.getUint32(i * HIT_BYTES, true);
      const score = this.view.getInt32(i * HIT_BYTES + 4, true);
      const len = fls_path(id, this.pathBuf);
      if (len === 0) continue;
      const relative = Buffer.from(this.pathBuf.buffer, 0, len).toString("utf8");
      const path = joinPath(this.root, relative);
      const title = baseName(relative);
      const match = fuzzyMatch(title, term);
      const marks = match === null ? [] : match.positions;
      const dir = fls_is_dir(id);
      // Size and date for the subtitle; a vanished file keeps its row.
      let size = -1;
      let modified = 0;
      if (fls_stat(path, this.statBuf) > 0) {
        size = dir ? -1 : this.statView.getFloat64(0, true);
        modified = this.statView.getFloat64(8, true);
      }
      rows.push(
        new Row(
          dir ? KIND_FOLDER : KIND_FILE,
          "file:" + path,
          title,
          displayPath(parentPath(path), this.home),
          path,
          ACTION_OPEN,
          marks,
          score,
          dir ? "" : extensionOf(title),
          size,
          modified,
        ),
      );
    }
    return rows;
  }
}
