/*
 * The AppKit half of the platform layer: the pasteboard, paste delivery and
 * app names. Only floodlight-clipd and the panel link it, so the TUI starts
 * without loading AppKit (flplatform.h has the TUI's own calls). flmac.m
 * implements it on macOS; flnative_stub.c answers "not available" elsewhere.
 */
#ifndef FLNATIVE_H
#define FLNATIVE_H

#include <stddef.h>
#include <stdint.h>

/* The pasteboard's change count, or -1 where there is no pasteboard. */
int32_t flm_change_count(void);
/* Reads the pasteboard into `out` as types RS files RS text RS image RS
 * source, lists split by US; holds any image's data for flc_record_image.
 * -(bytes needed) when `out` is too small. */
int32_t flm_read_capture(uint8_t *out, size_t cap);
/* The image data the last flm_read_capture kept; 0 when none. */
size_t flm_pending_png(const uint8_t **out);
size_t flm_pending_tiff(const uint8_t **out);
size_t flm_pending_thumbnail(const uint8_t **out);

/* Writes to the pasteboard, marked as Floodlight's own write. */
int32_t flm_write_text(const uint8_t *text, size_t len);
int32_t flm_write_file(const uint8_t *path, size_t len);
int32_t flm_write_image(const uint8_t *png, size_t png_len, const uint8_t *tiff, size_t tiff_len);

/* Brings `pid` forward and posts ⌘V to it; asks for Accessibility once. */
int32_t flm_paste_to(int32_t pid);
int32_t flm_frontmost_pid(void);
/* The display name of the app with this bundle id; 0 when unknown. */
int32_t flm_app_name(const uint8_t *bundle_id, size_t len, uint8_t *out, size_t cap);

#endif
