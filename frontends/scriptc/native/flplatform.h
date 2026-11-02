/*
 * The TUI's own platform calls (flplatform.c): plain C, no frameworks.
 */
#ifndef FLPLATFORM_H
#define FLPLATFORM_H

#include <stddef.h>
#include <stdint.h>

/* 1 with Full Disk Access, 0 without, -1 when it cannot be told. */
int32_t flm_full_disk_access(void);
/* The .app bundle of the terminal this process runs in, the one the grant
 * belongs to; 0 when there is none. */
int32_t flm_host_app(uint8_t *out, size_t cap);

#endif
