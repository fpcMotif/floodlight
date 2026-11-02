/**
 * floodlight-clipd: the clipboard capture agent, and the TUI's hands on the
 * pasteboard.
 *
 * The TUI exits when it is dismissed, so it cannot watch the pasteboard.
 * This small process does: it polls the change count every 0.5 s, reads a
 * changed pasteboard through the platform layer, lets `entryFor` decide
 * what (if anything) to record, and writes the same store the board reads.
 * Run it at login with launch/com.floodlight.tui.clipd.plist.
 *
 * It also runs the TUI's copy and paste (`--copy`, `--copy-text`): those
 * need AppKit, and linking AppKit into the TUI would cost it its cold start.
 */
import { appendFileSync, readFileSync } from "node:fs";
import { Capture, entryFor, newEntryId, pruneCutoff } from "./clip-capture";
import { CLIP_FILE, CLIP_IMAGE, ClipEntry } from "./clip-entry";
import { SqliteClipStore } from "./clip-sqlite";
import { ensureDir } from "./index-file";
import { fls_sleep_ms, fls_wall_s } from "./native";
import {
  flc_copy_image,
  flc_record_image,
  flm_app_name,
  flm_change_count,
  flm_paste_to,
  flm_read_capture,
  flm_write_file,
  flm_write_text,
} from "./native-agent";
import { APP_NAMES_FILE, dataDir } from "./paths";

const POLL_MS = 500;
const RS = "\x1e";
const US = "\x1f";

class Options {
  data = "";
  /** Record this text as one capture and exit: the store's end-to-end check. */
  recordText = "";
  recordTypes = "";
  once = false;
  copyId = "";
  copyText = "";
  pastePid = 0;
}

/** The store, plus the image calls that need the agent's pasteboard data. */
class AgentClipStore extends SqliteClipStore {
  protected recordImage(entry: ClipEntry, imageHash: string): boolean {
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
}

/**
 * Display names for the bundle ids the history holds, appended to a small
 * file the board reads: it has no AppKit to ask.
 */
class AppNames {
  private readonly known = new Set<string>();
  private readonly buf = new Uint8Array(1024);

  constructor(private readonly path: string) {
    let text = "";
    try {
      text = readFileSync(path, "utf8");
    } catch {
      return;
    }
    for (const line of text.split("\n")) {
      const tab = line.indexOf("\t");
      if (tab > 0) this.known.add(line.slice(0, tab));
    }
  }

  note(bundleId: string): void {
    if (bundleId.length === 0 || this.known.has(bundleId)) return;
    this.known.add(bundleId);
    const n = flm_app_name(bundleId, this.buf);
    if (n <= 0) return;
    const name = Buffer.from(this.buf.buffer, 0, n).toString("utf8");
    try {
      appendFileSync(this.path, bundleId + "\t" + name + "\n");
    } catch {
      // A read-only data folder costs the board its names, nothing more.
    }
  }
}

function split(field: string): string[] {
  return field.length === 0 ? [] : field.split(US);
}

/** Reads the platform layer's capture record; see flm_read_capture. */
export function parseCapture(raw: string): Capture {
  const f = raw.split(RS);
  while (f.length < 5) f.push("");
  const image = split(f[3]);
  return new Capture(
    split(f[0]),
    split(f[1]),
    f[2],
    image.length >= 4 ? parseInt(image[0], 10) : 0,
    image.length >= 4 ? parseInt(image[1], 10) : 0,
    image.length >= 4 ? parseInt(image[2], 10) : 0,
    image.length >= 4 ? image[3] : "",
    f[4],
  );
}

function captureOnce(store: SqliteClipStore, capture: Capture, home: string, names: AppNames): boolean {
  const entry = entryFor(capture, newEntryId(), fls_wall_s(), home, store.newest(), store.newestImageHash());
  if (entry === null || !store.record(entry, capture.imageHash)) return false;
  names.note(entry.sourceApp);
  return true;
}

/** Puts an entry back on the pasteboard, marked as Floodlight's own write. */
function copyEntry(store: SqliteClipStore, id: string): boolean {
  const entry = store.entry(id);
  if (entry === null) return false;
  if (entry.kind === CLIP_IMAGE) return flc_copy_image(id) > 0;
  if (entry.kind === CLIP_FILE) return flm_write_file(entry.text) > 0;
  return flm_write_text(store.fullText(id)) > 0;
}

function usage(): string {
  return [
    "usage: floodlight-clipd [--data DIR]          watch the pasteboard",
    "       floodlight-clipd --once                record the pasteboard once",
    "       floodlight-clipd --record-text TEXT [--types a,b]",
    "       floodlight-clipd --copy ID [--paste-pid PID]",
    "       floodlight-clipd --copy-text TEXT",
  ].join("\n");
}

function main(): void {
  const home = process.env.HOME ?? "/";
  const o = new Options();
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--data") o.data = args[++i];
    else if (args[i] === "--record-text") o.recordText = args[++i];
    else if (args[i] === "--types") o.recordTypes = args[++i];
    else if (args[i] === "--once") o.once = true;
    else if (args[i] === "--copy") o.copyId = args[++i];
    else if (args[i] === "--copy-text") o.copyText = args[++i];
    else if (args[i] === "--paste-pid") o.pastePid = parseInt(args[++i], 10);
    else {
      console.error(usage());
      process.exit(args[i] === "--help" ? 0 : 2);
    }
  }

  if (o.copyText.length > 0) {
    process.exit(flm_write_text(o.copyText) > 0 ? 0 : 1);
  }

  if (o.data.length === 0) o.data = dataDir(home);
  ensureDir(o.data);
  const store = new AgentClipStore(o.data + "/clipboard.sqlite");

  if (o.copyId.length > 0) {
    if (!copyEntry(store, o.copyId)) process.exit(1);
    // The TUI has exited by now, so its popup is closing and the target
    // can come forward for the keystroke.
    if (o.pastePid > 0 && flm_paste_to(o.pastePid) < 0) process.exit(1);
    return;
  }

  if (store.open() === 2) console.error("floodlight-clipd: history file would not open; keeping it in memory");
  store.prune(pruneCutoff(fls_wall_s()));
  const names = new AppNames(o.data + "/" + APP_NAMES_FILE);

  if (o.recordText.length > 0) {
    const types = o.recordTypes.length > 0 ? o.recordTypes.split(",") : ["public.utf8-plain-text"];
    const recorded = captureOnce(store, new Capture(types, [], o.recordText, 0, 0, 0, "", ""), home, names);
    console.log(recorded ? "recorded" : "skipped");
    return;
  }

  let last = flm_change_count();
  if (last < 0) {
    console.error("floodlight-clipd: this platform has no pasteboard to watch");
    process.exit(2);
  }
  const buf = new Uint8Array(64 * 1024);
  let big = buf;
  for (;;) {
    if (!o.once) fls_sleep_ms(POLL_MS);
    const count = flm_change_count();
    if (count !== last || o.once) {
      last = count;
      let n = flm_read_capture(big);
      if (n < 0) {
        big = new Uint8Array(-n + 1024);
        n = flm_read_capture(big);
      }
      if (n > 0) captureOnce(store, parseCapture(Buffer.from(big.buffer, 0, n).toString("utf8")), home, names);
      // A 32 KB text or a large image grew the buffer; drop it again.
      big = buf;
    }
    if (o.once) return;
  }
}

main();
