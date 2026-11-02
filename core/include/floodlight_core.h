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

/* ---- Live index ------------------------------------------------------
 *
 * An fl_live keeps one index current from file-system events: FSEvents on
 * macOS, inotify on Linux, or paths the shell passes to fl_live_notify.
 * Deleted entries are hidden by a tombstone bit and new ones sit in a small
 * overlay that search merges with the mapped file. Once the overlay passes
 * `overlay_limit` changes, a background thread rewrites the file, listing
 * only the folders that changed, and swaps it in.
 *
 * Threading: every fl_live_* call is safe from any thread at once, except
 * fl_live_close, which must not race any other call on the handle. Searches
 * share a lock for their duration and never wait on disk; an event takes the
 * lock alone only to flip tombstone bits or append to the overlay, and a
 * compaction only to swap the new file in. fl_live_notify reads the disk on the calling thread; calls for
 * the same path should come from one thread so they apply in order.
 *
 * Ids: a hit's id is valid only for the generation fl_live_search wrote.
 * After a compaction swaps the file, fl_live_relative_path and
 * fl_live_is_dir return 0 / false for an older generation; search again.
 *
 * Memory: searching allocates nothing. The overlay holds at most four times
 * `overlay_limit` entries; past that, new entries wait for the compaction
 * already queued.
 */
typedef struct fl_live fl_live;

/* Maps `index_path`, building it from `root` first if it is missing,
 * unreadable, or was built from another root, and starts the compaction
 * thread. `overlay_limit` 0 means the default (4096).
 * Returns 0 and sets *out, or a negative error code. */
int fl_live_open(const char *root, const char *index_path, uint32_t overlay_limit, fl_live **out);

/* Stops the watcher and the compaction thread, then unmaps. */
void fl_live_close(fl_live *live);

/* Starts the platform watcher on the root. Returns 0, or a negative error
 * code. A second call does nothing. */
int fl_live_watch(fl_live *live);

/* Something at `rel_path` (relative to the root, "" for the root itself)
 * changed. Reads the disk and updates the index to match. For a shell that
 * has its own event source; the watcher calls this itself. */
void fl_live_notify(fl_live *live, const char *rel_path);

/* Rewrites the file now and waits for the swap. Returns 0, or a negative
 * error code; on failure the pending work is kept for the next try. */
int fl_live_compact(fl_live *live);

/* As fl_search, over the mapped file and the overlay together. Writes the
 * generation the hits belong to into *generation if it is not NULL. */
uint32_t fl_live_search(fl_live *live, const char *query, fl_hit *out, uint32_t cap, uint64_t *generation);

/* As fl_relative_path. Returns 0 also when `generation` is not the current
 * one or the entry has been deleted since the search. */
uint32_t fl_live_relative_path(fl_live *live, uint64_t generation, uint32_t id, char *buf, uint32_t cap);

bool fl_live_is_dir(fl_live *live, uint64_t generation, uint32_t id);

#ifdef __cplusplus
}
#endif

#endif
