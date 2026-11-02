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
