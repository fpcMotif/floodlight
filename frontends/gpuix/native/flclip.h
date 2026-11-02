/*
 * Clipboard History on SQLite (flclip.c), in the shapes bun:ffi binds
 * directly: borrowed spans in, scalars out, rows serialized into a buffer.
 */
#ifndef FLCLIP_H
#define FLCLIP_H

#include <stddef.h>
#include <stdint.h>

int32_t flc_open(const uint8_t *path, size_t len);
int32_t flc_list(const uint8_t *query, size_t qlen, int32_t limit, uint8_t *out, size_t cap);
int32_t flc_newest(uint8_t *out, size_t cap);
int32_t flc_record(const uint8_t *id, size_t id_len, const uint8_t *text, size_t text_len, const uint8_t *kind,
                   size_t kind_len, double created, const uint8_t *source, size_t source_len,
                   const uint8_t *content_kind, size_t ck_len, const uint8_t *content_detail, size_t cd_len);
int32_t flc_record_image(const uint8_t *id, size_t id_len, double created, const uint8_t *source, size_t source_len,
                         const uint8_t *hash, size_t hash_len, int32_t width, int32_t height, int32_t bytes);
int32_t flc_set_pinned(const uint8_t *id, size_t id_len, int32_t pinned, double now);
int32_t flc_delete(const uint8_t *id, size_t id_len);
int32_t flc_prune(double cutoff);
int32_t flc_text(const uint8_t *id, size_t id_len, uint8_t *out, size_t cap);
int32_t flc_copy_image(const uint8_t *id, size_t id_len);
int32_t flc_export_image(const uint8_t *id, size_t id_len, const uint8_t *path, size_t path_len);

#endif
