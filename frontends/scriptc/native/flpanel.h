/*
 * The Cocoa panel's C surface, called through `ffi-panel.json`. Event codes
 * are mirrored in src/panel.ts.
 */
#ifndef FLPANEL_H
#define FLPANEL_H

#include <stddef.h>
#include <stdint.h>

enum {
    FLP_EV_NONE = 0,
    FLP_EV_QUERY = 1,
    FLP_EV_UP = 2,
    FLP_EV_DOWN = 3,
    FLP_EV_ENTER = 4,
    FLP_EV_REVEAL = 5,
    FLP_EV_ESCAPE = 6,
    FLP_EV_HOTKEY = 7,
    FLP_EV_HIDDEN = 8,
    FLP_EV_SELECT_INDEX = 9,
    FLP_EV_OPEN_INDEX = 10,
};

/* 1 on success; -1 off the main thread; -2 if the hotkey is taken. */
int32_t flp_start(int32_t hotkey);
/* Pumps AppKit until a script-visible event, or the timeout (-1: forever). */
int32_t flp_wait(int32_t timeout_ms);
/* The row index of the last SELECT_INDEX / OPEN_INDEX. */
int32_t flp_event_arg(void);
uint32_t flp_query(uint8_t *out, size_t cap);

void flp_clear_rows(void);
void flp_add_row(int32_t kind, const uint8_t *title, size_t title_len, const uint8_t *detail, size_t detail_len,
                 const uint8_t *path, size_t path_len, const uint8_t *marks, size_t marks_len);
void flp_commit(int32_t selection);
void flp_select(int32_t selection);

double flp_show(void);
void flp_hide(void);
uint8_t flp_visible(void);

#endif
