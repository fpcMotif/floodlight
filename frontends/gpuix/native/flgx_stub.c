/*
 * The window layer where there is no AppKit (flgx.h): no panel, no hotkeys,
 * no glass. It exists so the headless tests on Linux load the same library
 * and symbol set as the app. Opening falls back to xdg-open.
 */
#include "flgx.h"

#include "flshim.h"

int32_t flg_start(void) { return 0; }
int32_t flg_adopt_window(void) { return -1; }
int32_t flg_apply_material(void) { return FLG_MATERIAL_SOLID; }
int32_t flg_dark(void) { return 0; }
void flg_set_size(double width, double height) {
    (void)width;
    (void)height;
}
double flg_show(double width, double height) {
    (void)width;
    (void)height;
    return -1;
}
void flg_show_at(double x, double y, double width, double height) {
    (void)x;
    (void)y;
    (void)width;
    (void)height;
}
void flg_hide(void) {}
void flg_order_out(void) {}
uint8_t flg_visible(void) { return 0; }
int32_t flg_wait(int32_t timeout_ms) {
    fls_sleep_ms(timeout_ms);
    return FLG_EV_NONE;
}
int32_t flg_next_event(void) { return FLG_EV_NONE; }
void flg_post_hotkey(int32_t event) { (void)event; }
int32_t flg_open(const uint8_t *target, size_t len, int32_t reveal) { return fls_open(target, len, reveal); }
int32_t flg_icon(const uint8_t *path, size_t path_len, const uint8_t *out, size_t out_len, int32_t size) {
    (void)path;
    (void)path_len;
    (void)out;
    (void)out_len;
    (void)size;
    return 0;
}
int32_t flg_settings_frame(uint8_t *out, size_t cap) {
    (void)out;
    (void)cap;
    return 0;
}
int32_t flg_drag_source(double x, double y, double width, double height, const uint8_t *path, size_t len) {
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    (void)path;
    (void)len;
    return 0;
}
void flg_release_memory(void) {}
