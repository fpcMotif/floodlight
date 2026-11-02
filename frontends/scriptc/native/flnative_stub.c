/*
 * The platform layer where there is no macOS (flnative.h): no pasteboard,
 * no paste target, no TCC. Every call says so, and the frontend hides the
 * features that need it.
 */
#include "flnative.h"

int32_t flm_change_count(void) { return -1; }
int32_t flm_read_capture(uint8_t *out, size_t cap) {
    (void)out;
    (void)cap;
    return 0;
}
size_t flm_pending_png(const uint8_t **out) {
    *out = 0;
    return 0;
}
size_t flm_pending_tiff(const uint8_t **out) {
    *out = 0;
    return 0;
}
size_t flm_pending_thumbnail(const uint8_t **out) {
    *out = 0;
    return 0;
}
int32_t flm_write_text(const uint8_t *text, size_t len) {
    (void)text;
    (void)len;
    return -1;
}
int32_t flm_write_file(const uint8_t *path, size_t len) {
    (void)path;
    (void)len;
    return -1;
}
int32_t flm_write_image(const uint8_t *png, size_t png_len, const uint8_t *tiff, size_t tiff_len) {
    (void)png;
    (void)png_len;
    (void)tiff;
    (void)tiff_len;
    return -1;
}
int32_t flm_paste_to(int32_t pid) {
    (void)pid;
    return -1;
}
int32_t flm_frontmost_pid(void) { return -1; }
int32_t flm_app_name(const uint8_t *bundle_id, size_t len, uint8_t *out, size_t cap) {
    (void)bundle_id;
    (void)len;
    (void)out;
    (void)cap;
    return 0;
}
