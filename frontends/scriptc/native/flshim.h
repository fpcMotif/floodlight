/*
 * The C surface the scriptc frontend calls through `ffi.json`. Every
 * signature here is one scriptc's FFI can express: scalars, borrowed byte
 * spans (pointer + length), and writable byte spans.
 */
#ifndef FLSHIM_H
#define FLSHIM_H

#include <stddef.h>
#include <stdint.h>

double fls_now_ms(void);
double fls_process_age_ms(void);
double fls_resident_bytes(void);
double fls_footprint_bytes(void);
void fls_sleep_ms(int32_t ms);

int32_t fls_tty_enter(void);
void fls_tty_leave(void);
int32_t fls_tty_size(void);
int32_t fls_read(uint8_t *buf, size_t cap, int32_t timeout_ms);
int32_t fls_write(const uint8_t *bytes, size_t len);

int32_t fls_open(const uint8_t *path, size_t len, int32_t reveal);

int32_t fls_index_open(const uint8_t *path, size_t len);
int32_t fls_index_build_async(const uint8_t *root, size_t root_len, const uint8_t *out, size_t out_len);
int32_t fls_index_poll(void);
int32_t fls_index_build_result(void);
uint32_t fls_search(const uint8_t *query, size_t len, uint8_t *out, size_t cap);
uint32_t fls_path(uint32_t id, uint8_t *out, size_t cap);
uint8_t fls_is_dir(uint32_t id);
double fls_file_age_s(const uint8_t *path, size_t len);

#endif
