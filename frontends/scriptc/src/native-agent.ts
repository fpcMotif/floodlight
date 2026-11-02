/**
 * The AppKit half of the platform layer (native/flmac.m, a stub off macOS)
 * and the store calls that touch the pasteboard, bound by ffi-agent.json.
 * Only floodlight-clipd and the panel import this: the TUI must start
 * without loading AppKit.
 */
export declare function flc_record_image(
  id: string,
  created: number,
  source: string,
  hash: string,
  width: number,
  height: number,
  bytes: number,
): number;
export declare function flc_copy_image(id: string): number;
export declare function flm_change_count(): number;
export declare function flm_read_capture(out: Uint8Array): number;
export declare function flm_write_text(text: string): number;
export declare function flm_write_file(path: string): number;
export declare function flm_paste_to(pid: number): number;
export declare function flm_frontmost_pid(): number;
export declare function flm_app_name(bundleId: string, out: Uint8Array): number;
