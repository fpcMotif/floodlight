/**
 * What a pasteboard change becomes: one entry to record, or nothing. Pure,
 * so the parity fixtures feed it captures; the capture agent feeds it what
 * the native layer read off the pasteboard.
 */
import { classify, CLIP_FILE, CLIP_IMAGE, CLIP_TEXT, ClipEntry } from "./clip-entry";

export const MAX_TEXT_BYTES = 32000;
export const MAX_IMAGE_BYTES = 15 * 1024 * 1024;
export const RETENTION_DAYS = 30;

/** Marks Floodlight's own writes, so pasting an old entry does not record it again. */
export const OWN_WRITE_TYPE = "com.floodlight.own-write";
const SKIPPED_TYPES = [
  "org.nspasteboard.ConcealedType",
  "org.nspasteboard.TransientType",
  "com.apple.is-sensitive",
  OWN_WRITE_TYPE,
];

/** One pasteboard state, as the native layer read it. */
export class Capture {
  constructor(
    readonly types: string[],
    /** File paths, in pasteboard order; empty when none. */
    readonly files: string[],
    /** Plain text, or "" when none. */
    readonly text: string,
    /** Encoded PNG or TIFF size; 0 when there is no image. */
    readonly imageBytes: number,
    readonly imageWidth: number,
    readonly imageHeight: number,
    /** A content hash, so a repeated image is recognized. */
    readonly imageHash: string,
    readonly sourceApp: string,
  ) {}
}

export function utf8Length(text: string): number {
  let n = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff) {
      n += 4;
      i++;
    } else n += 3;
  }
  return n;
}

/** Same content as the newest entry: a repeat, skipped. */
function repeats(entry: ClipEntry, newest: ClipEntry | null, hash: string, newestHash: string): boolean {
  if (newest === null || newest.kind !== entry.kind) return false;
  if (entry.kind === CLIP_IMAGE) return hash.length > 0 && hash === newestHash;
  return newest.text === entry.text;
}

/**
 * The entry to record for `capture`, or null to skip it. Files win over
 * images and images over text, as the pasteboard's richest form.
 */
export function entryFor(
  capture: Capture,
  id: string,
  now: number,
  home: string,
  newest: ClipEntry | null,
  newestImageHash: string,
): ClipEntry | null {
  for (const type of capture.types) if (SKIPPED_TYPES.indexOf(type) >= 0) return null;
  let entry: ClipEntry | null = null;
  if (capture.files.length > 0) {
    entry = new ClipEntry(id, capture.files[0], CLIP_FILE, now, capture.sourceApp, 0, "", "");
  } else if (capture.imageBytes > 0) {
    if (capture.imageBytes > MAX_IMAGE_BYTES) return null;
    entry = new ClipEntry(
      id,
      "",
      CLIP_IMAGE,
      now,
      capture.sourceApp,
      0,
      "",
      "",
      capture.imageWidth,
      capture.imageHeight,
      capture.imageBytes,
    );
  } else if (capture.text.trim().length > 0) {
    if (utf8Length(capture.text) > MAX_TEXT_BYTES) return null;
    const c = classify(capture.text, home);
    entry = new ClipEntry(id, capture.text, CLIP_TEXT, now, capture.sourceApp, 0, c.kind, c.detail);
  }
  if (entry === null || repeats(entry, newest, capture.imageHash, newestImageHash)) return null;
  return entry;
}

/** Entries older than this are pruned at launch; pinned ones are kept. */
export function pruneCutoff(now: number): number {
  return now - RETENTION_DAYS * 86400;
}

/** A random RFC 4122 v4 id, upper case like Foundation's `UUID().uuidString`. */
export function newEntryId(): string {
  const hex = "0123456789ABCDEF";
  let out = "";
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) out += "-";
    else if (i === 14) out += "4";
    else if (i === 19) out += hex.charAt(8 + Math.floor(Math.random() * 4));
    else out += hex.charAt(Math.floor(Math.random() * 16));
  }
  return out;
}
