/**
 * The running app: which surface is up (search, board, guidance or none),
 * the domain state behind it, and every call to the platform layer. React
 * components read it through `useController` and send it keys and text; they
 * never call native code themselves.
 *
 * Latency: a hotkey wakes `idle()` straight out of the AppKit pump, and the
 * hidden window already holds the empty search bar, so a summon is an
 * order-front with no React work before it. Memory: hiding drops every row,
 * entry and icon reference, shrinks the read buffers, collects garbage and
 * returns freed pages, so a waiting launcher holds only the runtime floor.
 */
import { existsSync } from "node:fs";
import { boardFilterIncludes, BoardAction, ClipBoard } from "../domain/clip-board";
import { entryFor, newEntryId, parseCapture, pruneCutoff } from "../domain/clip-capture";
import { CLIP_FILE, CLIP_IMAGE, ClipEntry, entryPath } from "../domain/clip-entry";
import { FDA_MISSING, FDA_SETTINGS_URL, FDA_WAITING, FdaFlow, POLL_MS } from "../domain/fda";
import { GUIDANCE_HEIGHT, GUIDANCE_WIDTH, panelSize } from "../domain/metrics";
import { handlePanelKey, PanelAction } from "../domain/panel";
import { App, SearchSession } from "../domain/session";
import { SqliteClipStore } from "../platform/clip-sqlite";
import { CoreFiles } from "../platform/core-files";
import { absorbBuild, prepareIndex, rebuildIndex } from "../platform/index-file";
import {
  appName,
  decode,
  dragSource,
  hostApp,
  native,
  open,
  settingsFrame,
  spawnDetached,
  writeFile,
  writeText,
} from "../platform/native";

export type Surface = "hidden" | "search" | "board" | "guidance";

const EV_HOTKEY_SEARCH = 1;
const EV_HOTKEY_BOARD = 2;
const EV_RESIGNED = 3;
const EV_APPEARANCE = 4;

/** While hidden, the AppKit pump wakes at least this often for the pasteboard. */
const IDLE_WAIT_MS = 500;
/** While shown, GPUIX pumps AppKit; queued events are read this often. */
const SHOWN_POLL_MS = 33;
/** Long enough for GPUI to present the cleared frame before the window leaves. */
const ORDER_OUT_DELAY_MS = 50;
/** Two hidden waits before collecting, so a quick re-summon does no GC. */
const GC_DELAY_MS = 1000;

/** The guidance panel's drag target, in its own top-left coordinates. */
export const GUIDANCE_DRAG = { x: 16, y: 56, width: 64, height: 64 };

export interface Paths {
  home: string;
  root: string;
  index: string;
}

export class Controller {
  surface: Surface = "hidden";
  dark = false;
  /** FLG_MATERIAL_*: 0 solid, 1 blur, 2 glass. React paints a surface only for 0. */
  material = 0;
  readonly session: SearchSession;
  readonly board: ClipBoard;
  readonly fda = new FdaFlow();
  /** The app ⌘V goes to, remembered when the board opens. */
  pasteTarget = -1;
  version = 0;
  /** Run on every hide, for caches the controller does not own (icons). */
  readonly onRelease: Array<() => void> = [];

  private readonly listeners = new Set<() => void>();
  private watchLast = -1;
  private readonly captureBuf = new Uint8Array(64 * 1024);
  private building = false;
  private shownTimer: ReturnType<typeof setInterval> | null = null;
  private gcTimer: ReturnType<typeof setTimeout> | null = null;
  private lastPoll = 0;
  private lastGrantPoll = 0;
  /** False in tests: nothing pumps AppKit until start() took the window. */
  private started = false;
  /** flg_adopt_window's last answer: 2 panel, 1 activating fallback, < 1 not yet. */
  window = 0;

  constructor(
    private readonly paths: Paths,
    apps: App[],
    private readonly files: CoreFiles,
    private readonly store: SqliteClipStore,
    private readonly clock: () => number = () => native.fls_wall_s(),
  ) {
    this.session = new SearchSession(apps, files);
    this.board = new ClipBoard(store, clock);
  }

  // ---- React subscription ---------------------------------------------------

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  snapshot = (): number => this.version;

  private emit(): void {
    this.version++;
    for (const listener of this.listeners) listener();
  }

  // ---- lifecycle ------------------------------------------------------------

  /** Opens the last index, starts a rebuild, prunes history, probes the grant. */
  boot(): void {
    this.building = prepareIndex(this.paths.index, this.paths.root, this.files);
    this.store.prune(pruneCutoff(this.clock()));
    this.fda.start(native.flm_full_disk_access());
    this.watchLast = native.flm_change_count();
  }

  /** Takes over the GPUIX window and starts the hidden-state pump. */
  start(): number {
    const hotkeys = native.flg_start();
    this.started = true;
    this.ensureWindow();
    this.scheduleIdle();
    return hotkeys;
  }

  /**
   * Takes over the GPUIX window once it exists: GPUIX opens it on a later
   * run-loop pass than render(), so this is retried until it succeeds. The
   * last result is kept for the measure script (FLG adopt codes).
   */
  ensureWindow(): boolean {
    if (this.window > 0) return true;
    // Before start() there is no app window to take, only whatever a test
    // harness opened.
    if (!this.started) return false;
    this.window = native.flg_adopt_window();
    if (this.window <= 0) return false;
    this.applyAppearance();
    return true;
  }

  private applyAppearance(): void {
    this.dark = native.flg_dark() === 1;
    this.material = native.flg_apply_material();
  }

  // ---- the event pumps ------------------------------------------------------

  private scheduleIdle(): void {
    if (!this.started) return;
    setTimeout(() => this.idle(), 0);
  }

  /** One AppKit pump while hidden: returns at a hotkey or after IDLE_WAIT_MS. */
  private idle(): void {
    if (this.surface !== "hidden") return;
    const event = native.flg_wait(IDLE_WAIT_MS);
    this.ensureWindow();
    this.background();
    if (event !== 0) this.handleEvent(event);
    if (this.surface === "hidden") this.scheduleIdle();
  }

  private startShownPoll(): void {
    if (!this.started || this.shownTimer !== null) return;
    this.shownTimer = setInterval(() => {
      for (let event = native.flg_next_event(); event !== 0; event = native.flg_next_event()) {
        this.handleEvent(event);
      }
      this.background();
    }, SHOWN_POLL_MS);
  }

  private stopShownPoll(): void {
    if (this.shownTimer !== null) clearInterval(this.shownTimer);
    this.shownTimer = null;
  }

  /** Work that runs whether or not the panel is up, at most twice a second. */
  background(): void {
    const now = native.fls_now_ms();
    if (now - this.lastPoll < IDLE_WAIT_MS - 10) return;
    this.lastPoll = now;
    this.capture();
    if (this.building && absorbBuild(this.paths.index, this.files)) {
      this.building = false;
      if (this.surface === "search") {
        this.session.refresh();
        this.emit();
      }
    }
    if (this.fda.polling() && now - this.lastGrantPoll >= POLL_MS) {
      this.lastGrantPoll = now;
      this.pollGrant();
    }
  }

  handleEvent(event: number): void {
    if (event === EV_HOTKEY_SEARCH) this.toggle("search");
    else if (event === EV_HOTKEY_BOARD) this.toggle("board");
    else if (event === EV_RESIGNED && this.surface !== "guidance") this.hide();
    else if (event === EV_APPEARANCE) {
      this.applyAppearance();
      this.emit();
    }
  }

  // ---- clipboard capture ----------------------------------------------------

  /** Records the pasteboard if it changed since the last look. */
  capture(): boolean {
    const count = native.flm_change_count();
    if (count < 0 || count === this.watchLast) return false;
    this.watchLast = count;
    let buf = this.captureBuf;
    let n = native.flm_read_capture(buf, buf.length);
    if (n < 0) {
      // A 32 KB text: read it once into a buffer that is dropped right after.
      buf = new Uint8Array(-n + 1024);
      n = native.flm_read_capture(buf, buf.length);
    }
    if (n <= 0) return false;
    const capture = parseCapture(decode(buf, n));
    const entry = entryFor(
      capture,
      newEntryId(),
      this.clock(),
      this.paths.home,
      this.store.newest(),
      this.store.newestImageHash(),
    );
    if (entry === null || !this.store.record(entry, capture.imageHash)) return false;
    if (this.surface === "board") {
      this.board.reload();
      this.emit();
    }
    return true;
  }

  // ---- show and hide --------------------------------------------------------

  toggle(surface: Surface): void {
    if (this.surface === surface) this.hide();
    else this.show(surface);
  }

  show(surface: Surface): void {
    this.cancelGc();
    const from = this.surface;
    this.surface = surface;
    if (surface === "board") {
      if (from === "hidden" || from === "search") this.capturePasteTarget();
      this.board.setQuery("");
    }
    this.ensureWindow();
    if (surface === "guidance") {
      this.showGuidance();
    } else {
      const size = panelSize(this.session.query.length > 0, surface === "board", this.noticeShown());
      if (from === "hidden") native.flg_show(size.width, size.height);
      else native.flg_set_size(size.width, size.height);
    }
    this.startShownPoll();
    this.emit();
  }

  private capturePasteTarget(): void {
    this.pasteTarget = native.flm_frontmost_pid();
  }

  /**
   * Hides at once, then lets React draw the empty search bar before the
   * window leaves the screen, so the next summon shows that frame, not this
   * one. `after` runs once the window is gone, before the hidden-state pump
   * starts: the pump blocks for up to IDLE_WAIT_MS, and a paste must not wait
   * behind it.
   */
  hide(after?: () => void): void {
    if (this.surface === "hidden") return;
    native.flg_hide();
    dragSource(0, 0, 0, 0, "");
    this.surface = "hidden";
    this.stopShownPoll();
    this.release();
    this.emit();
    this.gcTimer = setTimeout(() => this.collect(), GC_DELAY_MS);
    setTimeout(() => {
      native.flg_order_out();
      after?.();
      if (this.surface === "hidden") this.scheduleIdle();
    }, ORDER_OUT_DELAY_MS);
  }

  /** Drops what a hidden launcher does not need. */
  release(): void {
    this.session.clear();
    this.board.query = "";
    this.board.entries = [];
    this.board.selected = 0;
    this.board.menuOpen = false;
    this.store.shrink();
    for (const release of this.onRelease) release();
  }

  private collect(): void {
    this.gcTimer = null;
    if (this.surface !== "hidden") return;
    Bun.gc(true);
    native.flg_release_memory();
  }

  private cancelGc(): void {
    if (this.gcTimer !== null) clearTimeout(this.gcTimer);
    this.gcTimer = null;
  }

  // ---- search panel ---------------------------------------------------------

  noticeShown(): boolean {
    return this.fda.state !== 0;
  }

  setQuery(query: string): void {
    if (query === this.session.query) return;
    const hadQuery = this.session.query.length > 0;
    this.session.setQuery(query);
    if (hadQuery !== query.length > 0) {
      const size = panelSize(query.length > 0, false, this.noticeShown());
      native.flg_set_size(size.width, size.height);
    }
    this.emit();
  }

  panelKey(key: string): boolean {
    const action = handlePanelKey(this.session, key, this.fda.state === FDA_MISSING);
    if (action.name === "none") return false;
    this.runPanel(action);
    return true;
  }

  /** A click on row `index`: select it, then act as Return would. */
  openRow(index: number): void {
    this.session.selected = index;
    this.runPanel(handlePanelKey(this.session, "return", false));
  }

  private runPanel(action: PanelAction): void {
    const row = action.row;
    if (action.name === "open" && row !== null) {
      this.hide();
      open(row.target, false);
      return;
    }
    if (action.name === "copy" && row !== null) {
      writeText(row.target);
      this.hide();
      return;
    }
    if (action.name === "reveal" && row !== null) {
      this.hide();
      open(row.target, true);
      return;
    }
    if (action.name === "preview" && row !== null) {
      spawnDetached(["qlmanage", "-p", row.target]);
      return;
    }
    if (action.name === "hide") {
      this.hide();
      return;
    }
    if (action.name === "board") {
      this.show("board");
      return;
    }
    if (action.name === "grant") {
      this.beginGrant();
      return;
    }
    if (action.name === "mode") {
      const size = panelSize(this.session.query.length > 0, false, this.noticeShown());
      native.flg_set_size(size.width, size.height);
    }
    this.emit();
  }

  // ---- clipboard board ------------------------------------------------------

  boardQuery(query: string): void {
    if (query === this.board.query) return;
    this.board.setQuery(query);
    this.emit();
  }

  boardKey(key: string): boolean {
    const action = this.board.handle(key);
    if (action.name === "none") return false;
    this.runBoard(action);
    return true;
  }

  selectEntry(index: number): void {
    this.board.selected = index;
    this.board.generation++;
    this.emit();
  }

  /** The app name for an entry's source bundle id; cached by the native side. */
  sourceName(bundleId: string): string {
    return bundleId.length === 0 ? "" : appName(bundleId);
  }

  fullText(entry: ClipEntry): string {
    return entry.truncated ? this.store.fullText(entry.id) : entry.text;
  }

  /** The inspector's image: exported once per entry into the cache folder. */
  imagePath(entry: ClipEntry, cacheDir: string): string {
    const path = cacheDir + "/" + entry.id + ".png";
    if (existsSync(path)) return path;
    return this.store.exportImage(entry.id, path) ? path : "";
  }

  private toPasteboard(entry: ClipEntry): boolean {
    if (entry.kind === CLIP_IMAGE) return this.store.copyImage(entry.id);
    if (entry.kind === CLIP_FILE) return writeFile(entry.text);
    return writeText(this.fullText(entry));
  }

  private runBoard(action: BoardAction): void {
    const entry = action.entry;
    if (action.name === "close") {
      this.hide();
      return;
    }
    if (action.name === "exit") {
      this.show("search");
      return;
    }
    if (action.name === "paste" && entry !== null) {
      const target = this.pasteTarget;
      if (!this.toPasteboard(entry)) return;
      // After the panel is gone, so ⌘V lands in the app it came from.
      this.hide(() => native.flm_paste_to(target));
      return;
    }
    if (action.name === "copy" && entry !== null) {
      this.toPasteboard(entry);
      this.hide();
      return;
    }
    if (action.name === "reveal" && entry !== null) {
      this.hide();
      open(entryPath(entry), true);
      return;
    }
    if (action.name === "preview" && entry !== null) {
      const path = entryPath(entry);
      if (path.length > 0) spawnDetached(["qlmanage", "-p", path]);
      return;
    }
    this.emit();
  }

  boardFilterCount(filter: number): number {
    let n = 0;
    for (const entry of this.board.entries) if (boardFilterIncludes(filter, entry)) n++;
    return n;
  }

  // ---- Full Disk Access grant -----------------------------------------------

  /** The bundle the user drags into the list: this app, or its host terminal. */
  grantBundle(): string {
    return hostApp();
  }

  beginGrant(): void {
    if (!this.fda.beginGrant()) return;
    open(FDA_SETTINGS_URL, false);
    this.show("guidance");
  }

  /** Floats the guidance panel just under System Settings once it is open. */
  private showGuidance(): void {
    const frame = settingsFrame();
    const x = frame === null ? 80 : frame.x + (frame.width - GUIDANCE_WIDTH) / 2;
    const y = frame === null ? 80 : frame.y + frame.height + 12;
    native.flg_show_at(x, y, GUIDANCE_WIDTH, GUIDANCE_HEIGHT);
    const d = GUIDANCE_DRAG;
    dragSource(d.x, d.y, d.width, d.height, this.grantBundle());
  }

  private pollGrant(): void {
    const wasWaiting = this.fda.state === FDA_WAITING;
    if (this.fda.tick(native.flm_full_disk_access(), this.clock())) {
      this.building = rebuildIndex(this.paths.index, this.paths.root) || this.building;
      this.emit();
      return;
    }
    // The granted state shows briefly, then the guidance panel goes.
    if (this.surface === "guidance" && !wasWaiting && this.fda.state === 0) this.hide();
  }
}
