/*
 * nanospot-core: the Zig file index behind Nanospot's file search.
 *
 * Threading: a handle is immutable once open. Any number of threads may call
 * ns_search / ns_relative_path / ns_is_dir on one handle at once. Build a new
 * index with ns_index_build, open it, then close the old handle; the build
 * writes through a temporary file and a rename, so an open handle is never
 * affected by a rebuild.
 *
 * Memory: ns_index_open maps the file read-only and allocates one small
 * handle. Searching allocates nothing.
 */
#ifndef NANOSPOT_CORE_H
#define NANOSPOT_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ns_index ns_index;

typedef struct {
    uint32_t id;
    int32_t score;
} ns_hit;

/* Scans `root` and writes the index to `out_path`.
 * Returns the entry count (>= 0), or a negative error code. */
int ns_index_build(const char *root, const char *out_path);

/* Maps an index. Returns 0 and sets *out, or a negative error code. */
int ns_index_open(const char *path, ns_index **out);

void ns_index_close(ns_index *index);

uint32_t ns_index_count(const ns_index *index);

/* Space-separated terms, all of which must match. Writes up to `cap`
 * (at most 256) hits, best first, and returns how many. */
uint32_t ns_search(const ns_index *index, const char *query, ns_hit *out, uint32_t cap);

/* Writes the NUL-terminated root-relative path of `id` into `buf`.
 * Returns its length, or 0 if `id` is out of range or `cap` is too small. */
uint32_t ns_relative_path(const ns_index *index, uint32_t id, char *buf, uint32_t cap);

bool ns_is_dir(const ns_index *index, uint32_t id);

#ifdef __cplusplus
}
#endif

#endif
