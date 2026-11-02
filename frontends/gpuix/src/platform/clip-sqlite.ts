/** The real Clipboard History: native/flclip.c over the Swift app's schema. */
import { CLIP_IMAGE, ClipEntry } from "../domain/clip-entry";
import { ClipStore, MATCH_LIMIT, RECENT_LIMIT } from "../domain/clip-store";
import { decode, native, utf8 } from "./native";

const RS = "\x1e";
const US = "\x1f";

function num(field: string): number {
  return field.length === 0 ? 0 : parseFloat(field);
}

/** Splits the library's record form back into entries; see `put_row` in flclip.c. */
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

/**
 * Image bytes stay in SQLite and the native layer; only previews and facts
 * cross into JavaScript, so a 15 MiB image never lands on the JS heap.
 */
export class SqliteClipStore extends ClipStore {
  /** Grown on demand: a thousand previews fit in about a megabyte. */
  private buf = new Uint8Array(256 * 1024);
  /** 0: not opened yet. 1: on disk. 2: the file would not open, so this run
   * keeps history in memory. Opened on first use. */
  private state = 0;

  constructor(private readonly path: string) {
    super();
  }

  open(): number {
    if (this.state === 0) {
      const p = utf8(this.path);
      this.state = native.flc_open(p, p.length);
    }
    return this.state;
  }

  /** Drops the grown read buffer: the board is hidden and needs none. */
  shrink(): void {
    if (this.buf.length > 256 * 1024) this.buf = new Uint8Array(256 * 1024);
  }

  private read(fill: (out: Uint8Array) => number): string {
    this.open();
    for (;;) {
      const n = fill(this.buf);
      if (n >= 0) return decode(this.buf, n);
      if (this.buf.length >= 64 * 1024 * 1024) return "";
      this.buf = new Uint8Array(Math.max(this.buf.length * 4, -n + 1024));
    }
  }

  list(query: string): ClipEntry[] {
    const q = utf8(query.trim());
    const limit = q.length === 0 ? RECENT_LIMIT : MATCH_LIMIT;
    return parseRecords(this.read((out) => native.flc_list(q, q.length, limit, out, out.length)));
  }

  record(entry: ClipEntry, imageHash: string): boolean {
    this.open();
    const id = utf8(entry.id);
    const source = utf8(entry.sourceApp);
    if (entry.kind === CLIP_IMAGE) {
      const hash = utf8(imageHash);
      return (
        native.flc_record_image(
          id,
          id.length,
          entry.createdAt,
          source,
          source.length,
          hash,
          hash.length,
          entry.imageWidth,
          entry.imageHeight,
          entry.imageBytes,
        ) > 0
      );
    }
    const text = utf8(entry.text);
    const kind = utf8(entry.kind);
    const ck = utf8(entry.contentKind);
    const cd = utf8(entry.contentDetail);
    return (
      native.flc_record(
        id,
        id.length,
        text,
        text.length,
        kind,
        kind.length,
        entry.createdAt,
        source,
        source.length,
        ck,
        ck.length,
        cd,
        cd.length,
      ) > 0
    );
  }

  setPinned(id: string, pinned: boolean, now: number): boolean {
    this.open();
    const i = utf8(id);
    return native.flc_set_pinned(i, i.length, pinned ? 1 : 0, now) > 0;
  }

  remove(id: string): boolean {
    this.open();
    const i = utf8(id);
    return native.flc_delete(i, i.length) > 0;
  }

  prune(cutoff: number): number {
    this.open();
    return Math.max(0, native.flc_prune(cutoff));
  }

  fullText(id: string): string {
    const i = utf8(id);
    return this.read((out) => native.flc_text(i, i.length, out, out.length));
  }

  newest(): ClipEntry | null {
    const entries = parseRecords(this.read((out) => native.flc_newest(out, out.length)));
    return entries.length > 0 ? entries[0] : null;
  }

  newestImageHash(): string {
    return hashField(this.read((out) => native.flc_newest(out, out.length)));
  }

  /** Puts a stored image back on the pasteboard, marked as our own write. */
  copyImage(id: string): boolean {
    this.open();
    const i = utf8(id);
    return native.flc_copy_image(i, i.length) > 0;
  }

  /** Writes a stored image to `path`, for the inspector and Quick Look. */
  exportImage(id: string, path: string): boolean {
    this.open();
    const i = utf8(id);
    const p = utf8(path);
    return native.flc_export_image(i, i.length, p, p.length) > 0;
  }
}
