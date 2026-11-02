/**
 * The one native library this frontend loads beside GPUIX's own addon:
 * native/*.{c,m} linked with the Zig core, bound through bun:ffi. bun:ffi
 * compiles each binding to a direct call, so a keystroke's search costs one C
 * call with no Node-API marshalling, and spans go in as borrowed buffers so
 * nothing native is copied onto the JS heap.
 *
 * Domain modules never import this file; only src/platform and src/main do.
 */
import { dlopen, FFIType } from "bun:ffi";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";

const { f64, i32, u32, u8, u64, ptr, void: none } = FFIType;

const SYMBOLS = {
  fls_now_ms: { args: [], returns: f64 },
  fls_process_age_ms: { args: [], returns: f64 },
  fls_footprint_bytes: { args: [], returns: f64 },
  fls_resident_bytes: { args: [], returns: f64 },
  fls_sleep_ms: { args: [i32], returns: none },
  fls_wall_s: { args: [], returns: f64 },
  fls_index_open: { args: [ptr, u64], returns: i32 },
  fls_index_build_async: { args: [ptr, u64, ptr, u64], returns: i32 },
  fls_index_poll: { args: [], returns: i32 },
  fls_index_build_result: { args: [], returns: i32 },
  fls_search: { args: [ptr, u64, ptr, u64], returns: u32 },
  fls_path: { args: [u32, ptr, u64], returns: u32 },
  fls_is_dir: { args: [u32], returns: u8 },
  fls_file_age_s: { args: [ptr, u64], returns: f64 },
  fls_spawn: { args: [ptr, u64], returns: i32 },
  fls_stat: { args: [ptr, u64, ptr, u64], returns: i32 },

  flc_open: { args: [ptr, u64], returns: i32 },
  flc_list: { args: [ptr, u64, i32, ptr, u64], returns: i32 },
  flc_newest: { args: [ptr, u64], returns: i32 },
  flc_record: {
    args: [ptr, u64, ptr, u64, ptr, u64, f64, ptr, u64, ptr, u64, ptr, u64],
    returns: i32,
  },
  flc_record_image: { args: [ptr, u64, f64, ptr, u64, ptr, u64, i32, i32, i32], returns: i32 },
  flc_set_pinned: { args: [ptr, u64, i32, f64], returns: i32 },
  flc_delete: { args: [ptr, u64], returns: i32 },
  flc_prune: { args: [f64], returns: i32 },
  flc_text: { args: [ptr, u64, ptr, u64], returns: i32 },
  flc_copy_image: { args: [ptr, u64], returns: i32 },
  flc_export_image: { args: [ptr, u64, ptr, u64], returns: i32 },

  flm_change_count: { args: [], returns: i32 },
  flm_read_capture: { args: [ptr, u64], returns: i32 },
  flm_write_text: { args: [ptr, u64], returns: i32 },
  flm_write_file: { args: [ptr, u64], returns: i32 },
  flm_paste_to: { args: [i32], returns: i32 },
  flm_frontmost_pid: { args: [], returns: i32 },
  flm_app_name: { args: [ptr, u64, ptr, u64], returns: i32 },
  flm_full_disk_access: { args: [], returns: i32 },
  flm_host_app: { args: [ptr, u64], returns: i32 },

  flg_start: { args: [], returns: i32 },
  flg_adopt_window: { args: [], returns: i32 },
  flg_apply_material: { args: [], returns: i32 },
  flg_dark: { args: [], returns: i32 },
  flg_set_size: { args: [f64, f64], returns: none },
  flg_show: { args: [f64, f64], returns: f64 },
  flg_show_at: { args: [f64, f64, f64, f64], returns: none },
  flg_hide: { args: [], returns: none },
  flg_order_out: { args: [], returns: none },
  flg_visible: { args: [], returns: u8 },
  flg_wait: { args: [i32], returns: i32 },
  flg_next_event: { args: [], returns: i32 },
  flg_post_hotkey: { args: [i32], returns: none },
  flg_open: { args: [ptr, u64, i32], returns: i32 },
  flg_icon: { args: [ptr, u64, ptr, u64, i32], returns: i32 },
  flg_settings_frame: { args: [ptr, u64], returns: i32 },
  flg_drag_source: { args: [f64, f64, f64, f64, ptr, u64], returns: i32 },
  flg_release_memory: { args: [], returns: none },
} as const;

function libraryPath(): string {
  const fromEnv = process.env.FLOODLIGHT_GPUIX_LIB ?? "";
  if (fromEnv.length > 0) return fromEnv;
  const name = process.platform === "darwin" ? "libfloodlight_gpuix.dylib" : "libfloodlight_gpuix.so";
  // Packaged: beside the executable in Contents/MacOS. Development: build/.
  const beside = join(dirname(process.execPath), name);
  if (existsSync(beside)) return beside;
  return join(import.meta.dir, "..", "..", "build", name);
}

const lib = dlopen(libraryPath(), SYMBOLS).symbols;
export const native = lib;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** UTF-8 bytes for a span argument; pass `s.length` beside it. */
export function utf8(text: string): Uint8Array {
  return encoder.encode(text);
}

export function decode(bytes: Uint8Array, length: number): string {
  return length <= 0 ? "" : decoder.decode(bytes.subarray(0, length));
}

// ---- span-shaped wrappers, the only callers of the raw symbols above ------

export function indexOpen(path: string): number {
  const p = utf8(path);
  return lib.fls_index_open(p, p.length);
}

export function indexBuildAsync(root: string, out: string): number {
  const r = utf8(root);
  const o = utf8(out);
  return lib.fls_index_build_async(r, r.length, o, o.length);
}

export function fileAgeSeconds(path: string): number {
  const p = utf8(path);
  return lib.fls_file_age_s(p, p.length);
}

/** Runs `argv` detached; never waits for it. */
export function spawnDetached(argv: string[]): number {
  const a = utf8(argv.join("\x1f"));
  return lib.fls_spawn(a, a.length);
}

export function open(target: string, reveal: boolean): number {
  const t = utf8(target);
  return lib.flg_open(t, t.length, reveal ? 1 : 0);
}

export function iconFile(path: string, out: string, size: number): boolean {
  const p = utf8(path);
  const o = utf8(out);
  return lib.flg_icon(p, p.length, o, o.length, size) === 1;
}

export function writeText(text: string): boolean {
  const t = utf8(text);
  return lib.flm_write_text(t, t.length) > 0;
}

export function writeFile(path: string): boolean {
  const p = utf8(path);
  return lib.flm_write_file(p, p.length) > 0;
}

const nameBuf = new Uint8Array(1024);

export function appName(bundleId: string): string {
  const b = utf8(bundleId);
  return decode(nameBuf, lib.flm_app_name(b, b.length, nameBuf, nameBuf.length));
}

export function hostApp(): string {
  return decode(nameBuf, lib.flm_host_app(nameBuf, nameBuf.length));
}

const frameBuf = new Float64Array(4);

/** System Settings' window, top-left based, or null when it is not open. */
export function settingsFrame(): { x: number; y: number; width: number; height: number } | null {
  if (lib.flg_settings_frame(frameBuf, frameBuf.byteLength) !== 1) return null;
  return { x: frameBuf[0], y: frameBuf[1], width: frameBuf[2], height: frameBuf[3] };
}

export function dragSource(x: number, y: number, width: number, height: number, path: string): void {
  const p = utf8(path);
  lib.flg_drag_source(x, y, width, height, p, p.length);
}
