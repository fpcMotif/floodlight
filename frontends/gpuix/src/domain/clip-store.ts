/**
 * The Clipboard History store seam. `SqliteClipStore` (clip-sqlite.ts) is the
 * real one, on the Swift app's schema; `MemoryClipStore` backs the parity
 * fixtures and has the same list order and limits.
 */
import { CLIP_IMAGE, ClipEntry } from "./clip-entry";

/** The empty query lists this many of the newest entries, plus every pinned one. */
export const RECENT_LIMIT = 1000;
/** A filter query returns at most this many matches. */
export const MATCH_LIMIT = 200;

export abstract class ClipStore {
  /** Pinned first, oldest pin first; then the newest. */
  abstract list(query: string): ClipEntry[];
  abstract record(entry: ClipEntry, imageHash: string): boolean;
  abstract setPinned(id: string, pinned: boolean, now: number): boolean;
  abstract remove(id: string): boolean;
  /** Deletes unpinned entries created before `cutoff`; returns how many. */
  abstract prune(cutoff: number): number;
  /** The whole text, where `list` may have returned a preview. */
  abstract fullText(id: string): string;
  /** The most recently recorded entry, pinned or not, and its image hash. */
  abstract newest(): ClipEntry | null;
  abstract newestImageHash(): string;
}

function searchable(entry: ClipEntry): string {
  const dims =
    entry.kind === CLIP_IMAGE && entry.imageWidth > 0 ? " " + entry.imageWidth + "×" + entry.imageHeight : "";
  return (entry.text + dims).toLowerCase();
}

function pinOrder(a: ClipEntry, b: ClipEntry): number {
  if (a.isPinned() !== b.isPinned()) return a.isPinned() ? -1 : 1;
  if (a.isPinned()) return a.pinnedAt - b.pinnedAt;
  return b.createdAt - a.createdAt;
}

export class MemoryClipStore extends ClipStore {
  private entries: ClipEntry[] = [];
  private hashes = new Map<string, string>();
  private newestId = "";

  list(query: string): ClipEntry[] {
    const q = query.trim().toLowerCase();
    const sorted = this.entries.slice().sort(pinOrder);
    const out: ClipEntry[] = [];
    let recent = 0;
    for (const entry of sorted) {
      if (q.length > 0) {
        if (searchable(entry).indexOf(q) < 0) continue;
        out.push(entry);
        if (out.length >= MATCH_LIMIT) break;
      } else if (entry.isPinned()) {
        out.push(entry);
      } else if (recent < RECENT_LIMIT) {
        out.push(entry);
        recent++;
      }
    }
    return out;
  }

  record(entry: ClipEntry, imageHash: string): boolean {
    this.entries.push(entry);
    this.hashes.set(entry.id, imageHash);
    this.newestId = entry.id;
    return true;
  }

  setPinned(id: string, pinned: boolean, now: number): boolean {
    for (let i = 0; i < this.entries.length; i++) {
      const e = this.entries[i];
      if (e.id !== id) continue;
      this.entries[i] = new ClipEntry(
        e.id,
        e.text,
        e.kind,
        e.createdAt,
        e.sourceApp,
        pinned ? now : 0,
        e.contentKind,
        e.contentDetail,
        e.imageWidth,
        e.imageHeight,
        e.imageBytes,
      );
      return true;
    }
    return false;
  }

  remove(id: string): boolean {
    const before = this.entries.length;
    this.entries = this.entries.filter((e) => e.id !== id);
    return this.entries.length < before;
  }

  prune(cutoff: number): number {
    const before = this.entries.length;
    this.entries = this.entries.filter((e) => e.isPinned() || e.createdAt >= cutoff);
    return before - this.entries.length;
  }

  fullText(id: string): string {
    for (const e of this.entries) if (e.id === id) return e.text;
    return "";
  }

  newest(): ClipEntry | null {
    for (const e of this.entries) if (e.id === this.newestId) return e;
    return null;
  }

  newestImageHash(): string {
    return this.hashes.get(this.newestId) ?? "";
  }
}
