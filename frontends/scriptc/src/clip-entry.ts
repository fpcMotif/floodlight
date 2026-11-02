/**
 * Clipboard History entries and their classification (ADR 0009), ported from
 * the Swift `ClipboardEntry` and `ClipboardTextContent`. Pure, so the parity
 * fixtures check them headless.
 */
import { baseName, parentPath } from "./paths";

export const CLIP_TEXT = "text";
export const CLIP_FILE = "file";
export const CLIP_IMAGE = "image";

export const CONTENT_PLAIN = "plain";
export const CONTENT_LINK = "link";
export const CONTENT_COLOR = "color";
export const CONTENT_CODE = "code";
export const CONTENT_PATH = "path";

/** One stored entry, in the Swift `clipboard_entries` row shape. */
export class ClipEntry {
  constructor(
    readonly id: string,
    /** The text, the file path, or an image's name (often empty). */
    readonly text: string,
    readonly kind: string,
    /** Seconds since 1970, as the Swift store writes `created_at`. */
    readonly createdAt: number,
    readonly sourceApp: string,
    /** Seconds since 1970, or 0 when not pinned. */
    readonly pinnedAt: number,
    /** For a text entry: plain, link, color, code or path; "" otherwise. */
    readonly contentKind: string,
    /** The one fact the content kind carries: domain, #RRGGBB, language, file URL. */
    readonly contentDetail: string,
    readonly imageWidth: number = 0,
    readonly imageHeight: number = 0,
    readonly imageBytes: number = 0,
    /** True when `text` is a preview cut short; the store has the rest. */
    readonly truncated: boolean = false,
  ) {}

  isPinned(): boolean {
    return this.pinnedAt > 0;
  }
}

export class Classification {
  constructor(
    readonly kind: string,
    readonly detail: string,
  ) {}
}

function isNewline(c: string): boolean {
  return c === "\n" || c === "\r" || c === " " || c === " " || c === "\u0085";
}

function hexDigits(s: string): boolean {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    const ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);
    if (!ok) return false;
  }
  return true;
}

function hex2(n: number): string {
  const s = n.toString(16).toUpperCase();
  return s.length < 2 ? "0" + s : s;
}

export class Rgba {
  constructor(
    readonly r: number,
    readonly g: number,
    readonly b: number,
    /** -1 when the colour has no alpha. */
    readonly a: number,
  ) {}

  hex(): string {
    return "#" + hex2(this.r) + hex2(this.g) + hex2(this.b) + (this.a >= 0 ? hex2(this.a) : "");
  }

  css(): string {
    if (this.a < 0) return "rgb(" + this.r + ", " + this.g + ", " + this.b + ")";
    return "rgba(" + this.r + ", " + this.g + ", " + this.b + ", " + (this.a / 255).toFixed(2) + ")";
  }
}

/** `#RGB`, `#RRGGBB` or `#RRGGBBAA`, ASCII digits only; null otherwise. */
export function parseHexColor(text: string): Rgba | null {
  const t = text.trim();
  if (!t.startsWith("#")) return null;
  const d = t.slice(1);
  if ((d.length !== 3 && d.length !== 6 && d.length !== 8) || !hexDigits(d)) return null;
  if (d.length === 3) {
    return new Rgba(parseInt(d.charAt(0), 16) * 17, parseInt(d.charAt(1), 16) * 17, parseInt(d.charAt(2), 16) * 17, -1);
  }
  const r = parseInt(d.slice(0, 2), 16);
  const g = parseInt(d.slice(2, 4), 16);
  const b = parseInt(d.slice(4, 6), 16);
  return new Rgba(r, g, b, d.length === 8 ? parseInt(d.slice(6, 8), 16) : -1);
}

/** Percent-decodes a `file://` URL's path; "" when it is not one. */
function fileURLPath(url: string): string {
  if (!url.startsWith("file://")) return "";
  let rest = url.slice(7);
  // `file://localhost/x` and `file:///x` name the same file.
  if (rest.startsWith("localhost/")) rest = rest.slice(9);
  if (!rest.startsWith("/")) return "";
  try {
    return decodeURIComponent(rest);
  } catch {
    return "";
  }
}

export function fileURL(path: string): string {
  const parts = path.split("/");
  for (let i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i]);
  return "file://" + parts.join("/");
}

function localPath(text: string, home: string): string {
  const t = text.trim();
  if (t.length === 0) return "";
  for (const c of t) if (isNewline(c)) return "";
  if (t.startsWith("file://")) return fileURLPath(t);
  if (t.startsWith("~/")) return home + t.slice(1);
  if (t.startsWith("/")) return t;
  return "";
}

function linkDomain(text: string): string {
  const t = text.trim();
  let rest = "";
  if (t.startsWith("https://")) rest = t.slice(8);
  else if (t.startsWith("http://")) rest = t.slice(7);
  else return "";
  for (const c of rest) if (c === " " || isNewline(c)) return "";
  let end = 0;
  while (end < rest.length && "/?#".indexOf(rest.charAt(end)) < 0) end++;
  let host = rest.slice(0, end);
  const at = host.lastIndexOf("@");
  if (at >= 0) host = host.slice(at + 1);
  const colon = host.lastIndexOf(":");
  if (colon >= 0) host = host.slice(0, colon);
  host = host.toLowerCase();
  if (host.length === 0) return "";
  return host.startsWith("www.") ? host.slice(4) : host;
}

const CODE_MARKERS = ["func ", "struct ", "import ", "class ", "const ", "function ", "export "];

function isJSON(text: string): boolean {
  try {
    JSON.parse(text);
    return true;
  } catch {
    return false;
  }
}

function codeLanguage(text: string): string {
  const t = text.trim();
  if ((t.startsWith("{") && t.endsWith("}")) || (t.startsWith("[") && t.endsWith("]"))) {
    if (isJSON(t)) return "JSON";
  }
  for (const marker of CODE_MARKERS) if (t.indexOf(marker) >= 0) return "Code";
  if (
    t.startsWith("<!DOCTYPE") ||
    t.startsWith("<html") ||
    (t.startsWith("<") && t.endsWith(">") && t.indexOf("</") >= 0)
  ) {
    return "HTML";
  }
  return "";
}

/** The one classifier, run once when an entry is recorded. */
export function classify(text: string, home: string): Classification {
  const path = localPath(text, home);
  if (path.length > 0) return new Classification(CONTENT_PATH, fileURL(path));
  const domain = linkDomain(text);
  if (domain.length > 0) return new Classification(CONTENT_LINK, domain);
  const color = parseHexColor(text);
  if (color !== null) return new Classification(CONTENT_COLOR, color.hex());
  const language = codeLanguage(text);
  if (language.length > 0) return new Classification(CONTENT_CODE, language);
  return new Classification(CONTENT_PLAIN, "");
}

/** The path an entry names: a file entry's text, or a path entry's URL. "" otherwise. */
export function entryPath(entry: ClipEntry): string {
  if (entry.kind === CLIP_FILE) return entry.text;
  if (entry.kind === CLIP_TEXT && entry.contentKind === CONTENT_PATH) return fileURLPath(entry.contentDetail);
  return "";
}

// ---- rows ------------------------------------------------------------------

/** The text's lines joined by single spaces, empty lines dropped, ends trimmed. */
export function previewTitle(text: string): string {
  let out = "";
  let pendingSpace = false;
  for (const c of text) {
    if (isNewline(c)) {
      pendingSpace = out.length > 0;
      continue;
    }
    if (pendingSpace) {
      out += " ";
      pendingSpace = false;
    }
    out += c;
  }
  out = out.trim();
  return out.length === 0 ? "(Empty text)" : out;
}

/** The row title the Swift board shows for this entry. */
export function entryTitle(entry: ClipEntry): string {
  if (entry.kind === CLIP_IMAGE) return entry.text.length === 0 ? "Image" : entry.text;
  const path = entryPath(entry);
  if (path.length > 0) {
    const name = path === "/" ? "/" : baseName(path);
    return name.length === 0 ? entry.text : name;
  }
  return previewTitle(entry.text);
}

/** The kind-specific fact a row's subtitle ends with: parent folder or dimensions. */
export function entryDetail(entry: ClipEntry): string {
  if (entry.kind === CLIP_IMAGE) {
    return entry.imageWidth > 0 ? entry.imageWidth + "×" + entry.imageHeight : "";
  }
  const path = entryPath(entry);
  if (path.length === 0) return "";
  const parent = baseName(parentPath(path));
  return parent === "/" || parent.length === 0 ? "" : parent;
}

/** The fixture and badge name of what the row is. */
export function entryBadge(entry: ClipEntry): string {
  if (entry.kind !== CLIP_TEXT) return entry.kind;
  return entry.contentKind.length === 0 ? CONTENT_PLAIN : entry.contentKind;
}
