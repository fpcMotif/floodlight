/*
 * The window half of the platform layer: everything GPUIX's `render()` does
 * not offer and the Floodlight panel needs. GPUIX opens one ordinary window;
 * this layer turns that window into a borderless, non-activating panel at
 * status level on every Space, puts the Liquid Glass slab behind GPUI's Metal
 * view, owns the Carbon hotkeys, and pumps AppKit while the panel is hidden
 * so a hotkey wakes JavaScript at once instead of at the next 100 ms tick.
 *
 * Main thread only. flgx_mac.m implements it; flgx_stub.c answers "not
 * available" elsewhere so the headless tests link the same library.
 */
#ifndef FLGX_H
#define FLGX_H

#include <stddef.h>
#include <stdint.h>

/* Events queued by AppKit callbacks, read by flg_wait or flg_next_event. */
enum {
    FLG_EV_NONE = 0,
    FLG_EV_HOTKEY_SEARCH = 1, /* ⌥Space */
    FLG_EV_HOTKEY_BOARD = 2,  /* ⌥⇧C */
    FLG_EV_RESIGNED = 3,      /* the panel lost key: the user clicked elsewhere */
    FLG_EV_APPEARANCE = 4,    /* light/dark or Reduce Transparency changed */
};

/* Materials flg_apply_material can pick. */
enum {
    FLG_MATERIAL_SOLID = 0,  /* Reduce Transparency: React paints the surface */
    FLG_MATERIAL_BLUR = 1,   /* before macOS 26: NSVisualEffectView */
    FLG_MATERIAL_GLASS = 2,  /* macOS 26: the clear NSGlassEffectView slab */
};

/* Accessory policy (no Dock icon), the Carbon handler and both hotkeys.
 * Returns a bitmask of the hotkeys registered (1 search, 2 board), or -1 off
 * the main thread. A hotkey another app holds is left out, not fatal. */
int32_t flg_start(void);

/* Restyles the window GPUIX opened. 2: a non-activating panel (class swap).
 * 1: the swap was refused (AppKit's KVO subclass is in the way), so showing
 * activates the app, as the Swift panel does. -1: no
 * window yet; -2: windows, but none of them GPUI's. Safe to call again. */
int32_t flg_adopt_window(void);

/* Picks the material for the current settings and installs it under GPUI's
 * view. Returns the FLG_MATERIAL_* in use. */
int32_t flg_apply_material(void);
/* 1 when the effective appearance is dark. */
int32_t flg_dark(void);

/* Resizes keeping the top edge and the horizontal centre still. GPUI's layer
 * is pinned to the top, so a frame drawn at the old size is cropped, never
 * stretched, until the next one lands. */
void flg_set_size(double width, double height);
/* Places the panel on the display under the pointer, as the Swift panel does,
 * and orders it front with key focus. Returns the milliseconds it took. */
double flg_show(double width, double height);
/* Puts the panel's top-left at (x, y) in top-left screen coordinates, for the
 * guidance panel under System Settings, and orders it front. */
void flg_show_at(double x, double y, double width, double height);
/* Hides at once (alpha 0); flg_order_out removes it from the
 * screen once React has drawn the cleared frame, so the next show starts
 * from an empty search bar and not the last query. */
void flg_hide(void);
void flg_order_out(void);
uint8_t flg_visible(void);
/* 1 while the panel is the key window: keys reach it, not the app below. */
uint8_t flg_is_key(void);
/* Writes the window class, its size and GPUIPanel's size: why a swap was refused. */
size_t flg_adopt_detail(uint8_t *out, size_t cap);

/* Pumps AppKit until an event or the timeout; returns the event or NONE. */
int32_t flg_wait(int32_t timeout_ms);
/* Pops a queued event without pumping: GPUIX's own tick pumps while shown. */
int32_t flg_next_event(void);
/* Queues a hotkey through the same handler a key press reaches, for the
 * measure script, which cannot post a real key press without Accessibility. */
void flg_post_hotkey(int32_t event);

/* Opens a path or URL in process (NSWorkspace), or reveals it in Finder. */
int32_t flg_open(const uint8_t *target, size_t len, int32_t reveal);
/* Writes the Finder icon for `path` as a `size`-pixel PNG at `out` unless it
 * is already there. Returns 1 when the file exists afterwards. */
int32_t flg_icon(const uint8_t *path, size_t path_len, const uint8_t *out, size_t out_len, int32_t size);

/* The frontmost System Settings window as four f64 (x, y from the top-left
 * of the main display, width, height). 1 when found. */
int32_t flg_settings_frame(uint8_t *out, size_t cap);
/* Covers the given rect of the panel (top-left coordinates) with a view that
 * drags `path` as a file, for the Full Disk Access list. width 0 removes it. */
int32_t flg_drag_source(double x, double y, double width, double height, const uint8_t *path, size_t len);

/* Returns freed malloc pages to the system. */
void flg_release_memory(void);

#endif
