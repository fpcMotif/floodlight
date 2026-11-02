/** File search through floodlight-core, the Zig index (ADR 0010). */
import { fuzzyMatch } from "../domain/match";
import { baseName, displayPath, joinPath, parentPath } from "../domain/paths";
import { ACTION_OPEN, extensionOf, KIND_FILE, KIND_FOLDER, Row } from "../domain/row";
import { FileSource } from "../domain/session";
import { decode, native, utf8 } from "./native";

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

/**
 * Searches the mapped index. Every buffer is allocated once and reused, so a
 * keystroke allocates only the rows it publishes.
 */
export class CoreFiles extends FileSource {
  private readonly hits = new Uint8Array(MAX_HITS * HIT_BYTES);
  private readonly view = new DataView(this.hits.buffer);
  private readonly pathBuf = new Uint8Array(4096);
  private readonly statBuf = new Float64Array(2);
  private readonly statBytes = new Uint8Array(this.statBuf.buffer);
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
    const q = utf8(query);
    const n = native.fls_search(q, q.length, this.hits, want * HIT_BYTES);
    const term = highlightTerm(query);
    const rows: Row[] = [];
    for (let i = 0; i < n; i++) {
      const id = this.view.getUint32(i * HIT_BYTES, true);
      const score = this.view.getInt32(i * HIT_BYTES + 4, true);
      const len = native.fls_path(id, this.pathBuf, this.pathBuf.length);
      if (len === 0) continue;
      const relative = decode(this.pathBuf, len);
      const path = joinPath(this.root, relative);
      const title = baseName(relative);
      const match = fuzzyMatch(title, term);
      const dir = native.fls_is_dir(id) === 1;
      // Size and date for the subtitle; a vanished file keeps its row.
      let size = -1;
      let modified = 0;
      const p = utf8(path);
      if (native.fls_stat(p, p.length, this.statBytes, this.statBytes.length) > 0) {
        size = dir ? -1 : this.statBuf[0];
        modified = this.statBuf[1];
      }
      rows.push(
        new Row(
          dir ? KIND_FOLDER : KIND_FILE,
          "file:" + path,
          title,
          displayPath(parentPath(path), this.home),
          path,
          ACTION_OPEN,
          match === null ? [] : match.positions,
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
