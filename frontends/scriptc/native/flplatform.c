/*
 * The platform calls the TUI makes on its own, in plain C: the Full Disk
 * Access probe and the terminal that hosts this process. Nothing here links
 * a framework, so the TUI starts without loading AppKit; everything that
 * needs AppKit lives in flmac.m, which only floodlight-clipd and the panel
 * link.
 */
#include "flplatform.h"

#if defined(__APPLE__)
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <unistd.h>

/* The TCC database is readable only with Full Disk Access: a plain open is
 * the cheapest probe, and it prompts nothing. */
int32_t flm_full_disk_access(void) {
    const char *home = getenv("HOME");
    if (home == NULL) return -1;
    char path[1024];
    snprintf(path, sizeof path, "%s/Library/Application Support/com.apple.TCC/TCC.db", home);
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
        close(fd);
        return 1;
    }
    return errno == EPERM || errno == EACCES ? 0 : -1;
}

/* Walks up the parent processes to the first one running from an app
 * bundle: the terminal, which is what TCC grants access to. */
int32_t flm_host_app(uint8_t *out, size_t cap) {
    pid_t pid = getppid();
    for (int depth = 0; depth < 16 && pid > 1; depth++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof path) > 0) {
            char *marker = strstr(path, ".app/Contents/MacOS/");
            if (marker != NULL) {
                size_t n = (size_t)(marker - path) + 4;
                if (n > cap) return 0;
                memcpy(out, path, n);
                return (int32_t)n;
            }
        }
        struct proc_bsdinfo info;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) break;
        pid = (pid_t)info.pbi_ppid;
    }
    return 0;
}

#else

int32_t flm_full_disk_access(void) { return 1; }

int32_t flm_host_app(uint8_t *out, size_t cap) {
    (void)out;
    (void)cap;
    return 0;
}

#endif
