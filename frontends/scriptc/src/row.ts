/**
 * One published result row, and the kinds and actions it can carry. Shared
 * by the TUI, the Cocoa panel and the parity fixtures.
 */

export const KIND_APP = 0;
export const KIND_FOLDER = 1;
export const KIND_FILE = 2;
export const KIND_WEB = 3;
export const KIND_CALCULATOR = 4;
export const KIND_SETTING = 5;

/** Open `target` (a path or a URL) with the system opener. */
export const ACTION_OPEN = 0;
/** Put `target` on the pasteboard. */
export const ACTION_COPY = 1;

/** The fixture spelling of each kind, and the TUI's badge. */
export function kindName(kind: number): string {
  if (kind === KIND_APP) return "app";
  if (kind === KIND_FOLDER) return "folder";
  if (kind === KIND_FILE) return "file";
  if (kind === KIND_WEB) return "web";
  if (kind === KIND_CALCULATOR) return "calculator";
  return "setting";
}

export class Row {
  constructor(
    readonly kind: number,
    /** Stable within one query, e.g. `web-search`, `app:/Applications/Safari.app`. */
    readonly id: string,
    readonly title: string,
    /** Where it lives or where it goes, already abbreviated for display. */
    readonly detail: string,
    /** The path, URL or text the action uses. */
    readonly target: string,
    readonly action: number,
    /** Highlighted UTF-16 offsets in `title`. */
    readonly marks: number[],
    readonly score: number,
    /** Lowercased file extension, or "" when the row is not a file. */
    readonly ext: string = "",
    /** Bytes, or -1 when unknown or not a file. */
    readonly size: number = -1,
    /** Seconds since the epoch, or 0 when unknown. */
    readonly modified: number = 0,
  ) {}

  /** Back-compat name for the target of a file or app row. */
  get path(): string {
    return this.target;
  }
}

export function extensionOf(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot <= 0 ? "" : name.slice(dot + 1).toLowerCase();
}
