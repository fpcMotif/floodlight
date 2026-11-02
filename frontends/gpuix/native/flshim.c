/*
 * Clock, memory, process spawning and the file index for the GPUIX frontend,
 * called from Bun through bun:ffi. Every function takes scalars and borrowed
 * (pointer, length) byte spans and writes results into caller-owned buffers,
 * so JavaScript never owns a native pointer and no call allocates on the JS
 * heap. The shapes match the scriptc frontend's shim (ADR 0013).
 *
 * Single-threaded except for the index build, which runs on one pthread and
 * hands its result back through an atomic the JS thread polls.
 */
#if defined(__linux__)
#define _GNU_SOURCE /* POSIX_SPAWN_SETSID */
#endif
#include "flshim.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "floodlight_core.h"

#if defined(__APPLE__)
#include <libproc.h>
#include <mach/mach.h>
#include <sys/proc_info.h>
#endif

extern char **environ;

/* ---- strings ---------------------------------------------------------- */

/* The FFI's spans are not NUL-terminated and may contain NULs; every POSIX
 * call here wants a C string. Paths past PATH_MAX are refused, not truncated,
 * so a long path can never resolve to a different, shorter one. */
static int span_to_cstr(const uint8_t *bytes, size_t len, char *out, size_t cap) {
    if (len + 1 > cap || (len > 0 && memchr(bytes, 0, len) != NULL)) return -1;
    if (len > 0) memcpy(out, bytes, len);
    out[len] = 0;
    return 0;
}

/* ---- clock and memory ------------------------------------------------- */

double fls_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

/* Time since the kernel created this process, so cold start includes exec,
 * dyld and runtime start-up rather than starting the clock at main(). */
double fls_process_age_ms(void) {
#if defined(__APPLE__)
    struct proc_bsdinfo info;
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof info) == (int)sizeof info) {
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        double started = (double)info.pbi_start_tvsec * 1e3 + (double)info.pbi_start_tvusec / 1e3;
        return (double)now.tv_sec * 1e3 + (double)now.tv_nsec / 1e6 - started;
    }
    return -1;
#else
    /* /proc/self/stat counts in clock ticks (10 ms), too coarse to be worth
     * reporting; the frontend falls back to its own monotonic start mark. */
    return -1;
#endif
}

double fls_resident_bytes(void) {
#if defined(__APPLE__)
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return (double)info.resident_size;
#else
    long pages = 0, resident = 0;
    FILE *f = fopen("/proc/self/statm", "r");
    if (f == NULL) return -1;
    int ok = fscanf(f, "%ld %ld", &pages, &resident) == 2;
    fclose(f);
    return ok ? (double)resident * (double)sysconf(_SC_PAGESIZE) : -1;
#endif
}

/* What Activity Monitor's Memory column shows: dirty plus compressed memory,
 * without the clean file-backed pages of the mapped index. */
double fls_footprint_bytes(void) {
#if defined(__APPLE__)
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return (double)info.phys_footprint;
#else
    return fls_resident_bytes();
#endif
}

/* ---- opening results -------------------------------------------------- */

/* Hands the path to the system opener and does not wait: the Linux path for
 * the headless tests. macOS opens in process through flg_open. The child
 * gets its own session, so it outlives this process. */
int32_t fls_open(const uint8_t *path, size_t len, int32_t reveal) {
    char target[4096];
    if (span_to_cstr(path, len, target, sizeof target) != 0) return -ENAMETOOLONG;

#if defined(__APPLE__)
    const char *opener = "/usr/bin/open";
    char *argv_reveal[] = {"open", "-R", "--", target, NULL};
    char *argv_open[] = {"open", "--", target, NULL};
#else
    const char *opener = "xdg-open";
    char *argv_reveal[] = {"xdg-open", target, NULL};
    char *argv_open[] = {"xdg-open", target, NULL};
#endif
    char **argv = reveal ? argv_reveal : argv_open;
    if (reveal) {
#if !defined(__APPLE__)
        /* xdg-open has no reveal; open the containing folder instead. */
        char *slash = strrchr(target, '/');
        if (slash != NULL && slash != target) *slash = 0;
#endif
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    /* Auto-reap: this process never waits on its openers. */
    signal(SIGCHLD, SIG_IGN);
    pid_t pid = 0;
    int rc = posix_spawnp(&pid, opener, &actions, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    return rc == 0 ? (int32_t)pid : -rc;
}

/* ---- file index ------------------------------------------------------- */

/* One live index per process, so TypeScript never holds a native pointer. */
static fl_index *live_index;

enum { BUILD_IDLE = 0, BUILD_RUNNING = 1, BUILD_DONE = 2 };
static _Atomic int build_state = BUILD_IDLE;
static _Atomic int build_result;
static char build_root[4096];
static char build_out[4096];

int32_t fls_index_open(const uint8_t *path, size_t len) {
    char p[4096];
    if (span_to_cstr(path, len, p, sizeof p) != 0) return -ENAMETOOLONG;
    fl_index *opened = NULL;
    int rc = fl_index_open(p, &opened);
    if (rc < 0) return rc;
    /* Searches run on this thread only, so nothing can be reading the old
     * mapping while it is closed. */
    if (live_index != NULL) fl_index_close(live_index);
    live_index = opened;
    return (int32_t)fl_index_count(live_index);
}

static void *build_thread(void *unused) {
    (void)unused;
    atomic_store(&build_result, fl_index_build(build_root, build_out));
    atomic_store(&build_state, BUILD_DONE);
    return NULL;
}

/* Starts a background rebuild. The build writes through a temporary file and
 * a rename, so the live mapping stays valid throughout. */
int32_t fls_index_build_async(const uint8_t *root, size_t root_len, const uint8_t *out, size_t out_len) {
    if (atomic_load(&build_state) == BUILD_RUNNING) return 0;
    if (span_to_cstr(root, root_len, build_root, sizeof build_root) != 0) return -ENAMETOOLONG;
    if (span_to_cstr(out, out_len, build_out, sizeof build_out) != 0) return -ENAMETOOLONG;
    atomic_store(&build_state, BUILD_RUNNING);
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&thread, &attr, build_thread, NULL);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        atomic_store(&build_state, BUILD_IDLE);
        return -rc;
    }
    return 1;
}

/* 0: no build pending. 1: still building. 2: finished, reported once; read
 * the outcome with fls_index_build_result. */
int32_t fls_index_poll(void) {
    int state = atomic_load(&build_state);
    if (state == BUILD_DONE) atomic_store(&build_state, BUILD_IDLE);
    return state;
}

/* The finished build's entry count, or its negative error code. */
int32_t fls_index_build_result(void) { return atomic_load(&build_result); }

/* Packs hits as little-endian (u32 id, i32 score) pairs, the layout of
 * fl_hit, so the script side reads them with one DataView. */
uint32_t fls_search(const uint8_t *query, size_t len, uint8_t *out, size_t cap) {
    if (live_index == NULL) return 0;
    char q[1024];
    if (span_to_cstr(query, len, q, sizeof q) != 0) return 0;
    uint32_t slots = (uint32_t)(cap / sizeof(fl_hit));
    if (slots > 256) slots = 256;
    return fl_search(live_index, q, (fl_hit *)(void *)out, slots);
}

uint32_t fls_path(uint32_t id, uint8_t *out, size_t cap) {
    if (live_index == NULL || cap == 0) return 0;
    return fl_relative_path(live_index, id, (char *)out, (uint32_t)(cap > UINT32_MAX ? UINT32_MAX : cap));
}

uint8_t fls_is_dir(uint32_t id) {
    return live_index != NULL && fl_is_dir(live_index, id) ? 1 : 0;
}

/* Seconds since the index file was last written, or -1 if it is missing. */
double fls_file_age_s(const uint8_t *path, size_t len) {
    char p[4096];
    struct stat st;
    if (span_to_cstr(path, len, p, sizeof p) != 0 || stat(p, &st) != 0) return -1;
    return difftime(time(NULL), st.st_mtime);
}

void fls_sleep_ms(int32_t ms) {
    struct timespec ts = {.tv_sec = ms / 1000, .tv_nsec = (long)(ms % 1000) * 1000000L};
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
}

/* Runs a program detached, like fls_open: `args` is the argv joined by US
 * (0x1f), program first, looked up on PATH. For `qlmanage -p`, which must
 * not block the JS thread while Quick Look loads. */
int32_t fls_spawn(const uint8_t *args, size_t len) {
    char buf[8192];
    char *argv[16];
    if (span_to_cstr(args, len, buf, sizeof buf) != 0) return -ENAMETOOLONG;
    int argc = 0;
    char *p = buf;
    argv[argc++] = p;
    for (; *p != 0; p++) {
        if (*p != 0x1f) continue;
        *p = 0;
        if (argc == 15) return -E2BIG;
        argv[argc++] = p + 1;
    }
    argv[argc] = NULL;

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    signal(SIGCHLD, SIG_IGN);
    pid_t pid = 0;
    int rc = posix_spawnp(&pid, argv[0], &actions, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    return rc == 0 ? (int32_t)pid : -rc;
}

/* Writes the file's size and modification time (f64 seconds, little-endian
 * as on every target) into `out`: 1 for a file, 2 for a folder, 0 when it
 * is gone. The subtitle's "12 KB · Today". */
int32_t fls_stat(const uint8_t *path, size_t len, uint8_t *out, size_t cap) {
    char p[4096];
    struct stat st;
    if (cap < 16 || span_to_cstr(path, len, p, sizeof p) != 0 || stat(p, &st) != 0) return 0;
    double size = (double)st.st_size;
    double mtime = (double)st.st_mtime;
    memcpy(out, &size, 8);
    memcpy(out + 8, &mtime, 8);
    return S_ISDIR(st.st_mode) ? 2 : 1;
}

/* Seconds since 1970, for entry timestamps (the store's `created_at`). */
double fls_wall_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}
