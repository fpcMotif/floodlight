/**
 * The Cocoa panel's C functions (native/flpanel.m), bound by the generated
 * build/ffi-panel.json. Only floodlight-panel imports this module.
 */

export declare function flp_start(hotkey: number): number;
export declare function flp_wait(timeoutMs: number): number;
export declare function flp_event_arg(): number;
export declare function flp_query(out: Uint8Array): number;
export declare function flp_clear_rows(): void;
export declare function flp_add_row(kind: number, title: string, detail: string, path: string, marks: string): void;
export declare function flp_commit(selection: number): void;
export declare function flp_select(selection: number): void;
export declare function flp_show(): number;
export declare function flp_hide(): void;
export declare function flp_visible(): boolean;
