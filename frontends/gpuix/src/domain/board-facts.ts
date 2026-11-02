/**
 * What the board's list rows and inspector say about an entry: the subtitle,
 * the glyph, the text counts and the actions menu titles. Pure, so the parity
 * fixtures check the same strings the React components draw.
 */
import { MENU_COPY, MENU_DELETE, MENU_PASTE, MENU_PIN, MENU_PREVIEW, MENU_REVEAL } from "./clip-board";
import { ClipEntry, entryBadge, entryDetail } from "./clip-entry";
import { formatAge } from "./format";

export function glyph(entry: ClipEntry): string {
  const b = entryBadge(entry);
  if (b === "link") return "↗";
  if (b === "color") return "■";
  if (b === "code") return "{";
  if (b === "path" || b === "file") return "▤";
  if (b === "image") return "▣";
  return "¶";
}

export const MENU_TITLES = new Map<string, string>([
  [MENU_PASTE, "Paste"],
  [MENU_COPY, "Copy"],
  [MENU_REVEAL, "Show in Finder"],
  [MENU_PREVIEW, "Quick Look"],
  [MENU_PIN, "Pin / Unpin"],
  [MENU_DELETE, "Delete"],
]);

export class TextCounts {
  constructor(
    readonly characters: number,
    readonly words: number,
    readonly lines: number,
  ) {}
}

export function countText(text: string): TextCounts {
  let characters = 0;
  let words = 0;
  let lines = text.length === 0 ? 0 : 1;
  let inWord = false;
  for (const ch of text) {
    characters++;
    if (ch === "\n") lines++;
    const space = ch === " " || ch === "\n" || ch === "\t" || ch === "\r";
    if (!space && !inWord) words++;
    inWord = !space;
  }
  return new TextCounts(characters, words, lines);
}

/** "Safari · 5m · Documents": the Swift board's subtitle. */
export function entrySubtitle(entry: ClipEntry, appName: string, now: number): string {
  const detail = entryDetail(entry);
  const head = (appName.length > 0 ? appName : "Clipboard") + " · " + formatAge(entry.createdAt, now);
  return detail.length > 0 ? head + " · " + detail : head;
}
