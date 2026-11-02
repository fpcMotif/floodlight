/**
 * The C functions this frontend calls, bound by `ffi.json` to
 * `native/flshim.c`. scriptc turns a direct call to each declaration into a
 * native call; it must stay a bodiless `declare function` with exactly these
 * parameter types for that to happen.
 */

export declare function fls_now_ms(): number;
export declare function fls_process_age_ms(): number;
export declare function fls_resident_bytes(): number;
export declare function fls_footprint_bytes(): number;
export declare function fls_sleep_ms(ms: number): void;

export declare function fls_tty_enter(): number;
export declare function fls_tty_leave(): void;
export declare function fls_tty_size(): number;
export declare function fls_read(buf: Uint8Array, timeoutMs: number): number;
export declare function fls_write(text: string): number;

export declare function fls_open(path: string, reveal: number): number;

export declare function fls_index_open(path: string): number;
export declare function fls_index_build_async(root: string, out: string): number;
export declare function fls_index_poll(): number;
export declare function fls_index_build_result(): number;
export declare function fls_search(query: string, out: Uint8Array): number;
export declare function fls_path(id: number, out: Uint8Array): number;
export declare function fls_is_dir(id: number): boolean;
export declare function fls_file_age_s(path: string): number;
export declare function fls_spawn(args: string): number;
export declare function fls_stat(path: string, out: Uint8Array): number;
export declare function fls_wall_s(): number;

// Clipboard History on SQLite (native/flclip.c).
export declare function flc_open(path: string): number;
export declare function flc_list(query: string, limit: number, out: Uint8Array): number;
export declare function flc_newest(out: Uint8Array): number;
export declare function flc_entry(id: string, out: Uint8Array): number;
export declare function flc_record(
  id: string,
  text: string,
  kind: string,
  created: number,
  source: string,
  contentKind: string,
  contentDetail: string,
): number;
export declare function flc_set_pinned(id: string, pinned: number, now: number): number;
export declare function flc_delete(id: string): number;
export declare function flc_prune(cutoff: number): number;
export declare function flc_text(id: string, out: Uint8Array): number;
export declare function flc_export_image(id: string, path: string): number;

// The TUI's own platform calls (native/flplatform.c), plain C with no frameworks.
export declare function flm_full_disk_access(): number;
export declare function flm_host_app(out: Uint8Array): number;
