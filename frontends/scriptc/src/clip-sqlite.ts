/** The real Clipboard History: native/flclip.c over the Swift app's schema. */
import { CLIP_IMAGE, ClipEntry } from "./clip-entry";
import { ClipStore, MATCH_LIMIT, RECENT_LIMIT } from "./clip-store";
import {
  flc_copy_image,
  flc_delete,
  flc_export_image,
  flc_list,
  flc_newest,
  flc_open,
  flc_prune,
  flc_record,
  flc_record_image,
  flc_set_pinned,
  flc_text,
} from "./native";

const RS = "\x1e";
const US = "\x1f";

function num(field: string): number {
  return field.length === 0 ? 0 : parseFloat(field);
}

/** Splits the shim's record form back into entries; see `put_row` in flclip.c. */
export function parseRecords(raw: string): ClipEntry[] {
  const out: ClipEntry[] = [];
  for (const record of raw.split(RS)) {
    if (record.length === 0) continue;
    const f = record.split(US);
    if (f.length < 13) continue;
    out.push(
      new ClipEntry(
        f[0],
        f[1],
        f[2],
        num(f[3]),
        f[4],
        num(f[5]),
        f[9],
        f[10],
        Math.round(num(f[6])),
        Math.round(num(f[7])),
        Math.round(num(f[8])),
        f[12] === "1",
      ),
    );
  }
  return out;
}

function hashField(raw: string): string {
  const f = raw.split(RS)[0].split(US);
  return f.length >= 13 ? f[11] : "";
}

export class SqliteClipStore extends ClipStore {
  /** Grown on demand: a thousand previews fit in about a megabyte. */
  private buf = new Uint8Array(256 * 1024);
  /** 0: not opened yet. 1: on disk. 2: the file would not open, so this run
   * keeps history in memory. Opened on first use, so a search-only run of
   * the TUI never pays for SQLite. */
  private state = 0;

  constructor(private readonly path: string) {
    super();
  }

  open(): number {
    if (this.state === 0) this.state = flc_open(this.path);
    return this.state;
  }

  private read(fill: (out: Uint8Array) => number): string {
    this.open();
    for (;;) {
      const n = fill(this.buf);
      if (n >= 0) return Buffer.from(this.buf.buffer, 0, n).toString("utf8");
      if (this.buf.length >= 64 * 1024 * 1024) return "";
      this.buf = new Uint8Array(this.buf.length * 4);
    }
  }

  list(query: string): ClipEntry[] {
    const q = query.trim();
    const limit = q.length === 0 ? RECENT_LIMIT : MATCH_LIMIT;
    return parseRecords(this.read((out) => flc_list(q, limit, out)));
  }

  record(entry: ClipEntry, imageHash: string): boolean {
    this.open();
    if (entry.kind === CLIP_IMAGE) {
      return (
        flc_record_image(
          entry.id,
          entry.createdAt,
          entry.sourceApp,
          imageHash,
          entry.imageWidth,
          entry.imageHeight,
          entry.imageBytes,
        ) > 0
      );
    }
    return (
      flc_record(
        entry.id,
        entry.text,
        entry.kind,
        entry.createdAt,
        entry.sourceApp,
        entry.contentKind,
        entry.contentDetail,
      ) > 0
    );
  }

  setPinned(id: string, pinned: boolean, now: number): boolean {
    this.open();
    return flc_set_pinned(id, pinned ? 1 : 0, now) > 0;
  }

  remove(id: string): boolean {
    this.open();
    return flc_delete(id) > 0;
  }

  prune(cutoff: number): number {
    this.open();
    return Math.max(0, flc_prune(cutoff));
  }

  fullText(id: string): string {
    this.open();
    for (;;) {
      const n = flc_text(id, this.buf);
      if (n >= 0) return Buffer.from(this.buf.buffer, 0, n).toString("utf8");
      this.buf = new Uint8Array(-n + 1024);
    }
  }

  newest(): ClipEntry | null {
    const entries = parseRecords(this.read((out) => flc_newest(out)));
    return entries.length > 0 ? entries[0] : null;
  }

  newestImageHash(): string {
    return hashField(this.read((out) => flc_newest(out)));
  }

  copyImage(id: string): boolean {
    this.open();
    return flc_copy_image(id) > 0;
  }

  exportImage(id: string, path: string): boolean {
    this.open();
    return flc_export_image(id, path) > 0;
  }
}
