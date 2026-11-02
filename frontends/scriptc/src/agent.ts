/**
 * floodlight-clipd: the clipboard capture agent.
 *
 * The TUI exits when it is dismissed, so it cannot watch the pasteboard.
 * This small process does: it polls the change count every 0.5 s, reads a
 * changed pasteboard through the platform layer, lets `entryFor` decide
 * what (if anything) to record, and writes the same store the board reads.
 * Run it at login with launch/com.floodlight.tui.clipd.plist.
 */
import { Capture, entryFor, newEntryId, pruneCutoff } from "./clip-capture";
import { SqliteClipStore } from "./clip-sqlite";
import { ensureDir } from "./index-file";
import { flm_change_count, flm_read_capture, fls_sleep_ms, fls_wall_s } from "./native";
import { dataDir } from "./paths";

const POLL_MS = 500;
const RS = "\x1e";
const US = "\x1f";

class Options {
  data = "";
  /** Record this text as one capture and exit: the store's end-to-end check. */
  recordText = "";
  recordTypes = "";
  once = false;
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

function captureOnce(store: SqliteClipStore, capture: Capture, home: string): boolean {
  const entry = entryFor(capture, newEntryId(), fls_wall_s(), home, store.newest(), store.newestImageHash());
  if (entry === null) return false;
  return store.record(entry, capture.imageHash);
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
    else {
      console.error("usage: floodlight-clipd [--data DIR] [--once] [--record-text TEXT [--types a,b]]");
      process.exit(args[i] === "--help" ? 0 : 2);
    }
  }
  if (o.data.length === 0) o.data = dataDir(home);
  ensureDir(o.data);
  const store = new SqliteClipStore(o.data + "/clipboard.sqlite");
  if (store.open() === 2) console.error("floodlight-clipd: history file would not open; keeping it in memory");
  store.prune(pruneCutoff(fls_wall_s()));

  if (o.recordText.length > 0) {
    const types = o.recordTypes.length > 0 ? o.recordTypes.split(",") : ["public.utf8-plain-text"];
    const recorded = captureOnce(store, new Capture(types, [], o.recordText, 0, 0, 0, "", ""), home);
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
      if (n > 0) captureOnce(store, parseCapture(Buffer.from(big.buffer, 0, n).toString("utf8")), home);
      // A 32 KB text or a large image grew the buffer; drop it again.
      big = buf;
    }
    if (o.once) return;
  }
}

main();
