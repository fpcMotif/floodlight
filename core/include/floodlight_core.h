/*
 * floodlight-core: the Zig file index behind Floodlight's file search.
 *
 * Threading: a handle is immutable once open. Any number of threads may call
 * fl_search / fl_relative_path / fl_is_dir on one handle at once. Build a new
 * index with fl_index_build, open it, then close the old handle; the build
 * writes through a temporary file and a rename, so an open handle is never
 * affected by a rebuild.
 *
 * Memory: fl_index_open maps the file read-only and allocates one small
 * handle. Searching allocates nothing.
 */
#ifndef FLOODLIGHT_CORE_H
#define FLOODLIGHT_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fl_index fl_index;

typedef struct {
    uint32_t id;
    int32_t score;
} fl_hit;

/* Scans `root` and writes the index to `out_path`.
 * Returns the entry count (>= 0), or a negative error code. */
int fl_index_build(const char *root, const char *out_path);

/* Maps an index. Returns 0 and sets *out, or a negative error code. */
int fl_index_open(const char *path, fl_index **out);

void fl_index_close(fl_index *index);

uint32_t fl_index_count(const fl_index *index);

/* Space-separated terms, all of which must match. Writes up to `cap`
 * (at most 256) hits, best first, and returns how many. */
uint32_t fl_search(const fl_index *index, const char *query, fl_hit *out, uint32_t cap);

/* Writes the NUL-terminated root-relative path of `id` into `buf`.
 * Returns its length, or 0 if `id` is out of range or `cap` is too small. */
uint32_t fl_relative_path(const fl_index *index, uint32_t id, char *buf, uint32_t cap);

bool fl_is_dir(const fl_index *index, uint32_t id);

#ifdef __cplusplus
}
#endif

#endif
