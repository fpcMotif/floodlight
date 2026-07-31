#ifndef FLOODLIGHT_FFF_H
#define FLOODLIGHT_FFF_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct FffResult {
    bool success;
    char *error;
    void *handle;
    int64_t int_value;
} FffResult;

typedef struct FffLocation {
    uint8_t tag;
    int32_t line;
    int32_t col;
    int32_t end_line;
    int32_t end_col;
} FffLocation;

typedef struct FffScore {
    int32_t total;
    int32_t base_score;
    int32_t filename_bonus;
    int32_t special_filename_bonus;
    int32_t frecency_boost;
    int32_t distance_penalty;
    int32_t current_file_penalty;
    int32_t combo_match_boost;
    int32_t path_alignment_bonus;
    bool exact_match;
    char *match_type;
} FffScore;

typedef struct FffFileItem {
    char *relative_path;
    char *file_name;
    char *git_status;
    uint64_t size;
    uint64_t modified;
    int64_t access_frecency_score;
    int64_t modification_frecency_score;
    int64_t total_frecency_score;
    bool is_binary;
} FffFileItem;

typedef struct FffSearchResult {
    struct FffFileItem *items;
    struct FffScore *scores;
    uint32_t count;
    uint32_t total_matched;
    uint32_t total_files;
    struct FffLocation location;
} FffSearchResult;

typedef struct FffDirItem {
    char *relative_path;
    char *dir_name;
    int32_t max_access_frecency;
} FffDirItem;

typedef struct FffDirSearchResult {
    struct FffDirItem *items;
    struct FffScore *scores;
    uint32_t count;
    uint32_t total_matched;
    uint32_t total_dirs;
} FffDirSearchResult;

typedef struct FffMixedItem {
    uint8_t item_type;
    char *relative_path;
    char *display_name;
    char *git_status;
    uint64_t size;
    uint64_t modified;
    int64_t access_frecency_score;
    int64_t modification_frecency_score;
    int64_t total_frecency_score;
    bool is_binary;
} FffMixedItem;

typedef struct FffMixedSearchResult {
    struct FffMixedItem *items;
    struct FffScore *scores;
    uint32_t count;
    uint32_t total_matched;
    uint32_t total_files;
    uint32_t total_dirs;
    struct FffLocation location;
} FffMixedSearchResult;

typedef struct FffScanProgress {
    uint64_t scanned_files_count;
    bool is_scanning;
    bool is_watcher_ready;
    bool is_warmup_complete;
} FffScanProgress;

FffResult *fff_create_instance3(
    const char *base_path,
    const char *frecency_db_path,
    const char *history_db_path,
    bool use_unsafe_no_lock,
    bool enable_mmap_cache,
    bool enable_content_indexing,
    bool watch,
    bool ai_mode,
    bool include_binary_files,
    const char *log_file_path,
    const char *log_level,
    uint64_t cache_budget_max_files,
    uint64_t cache_budget_max_bytes,
    uint64_t cache_budget_max_file_size
);

typedef struct FffGrepMatch FffGrepMatch;
typedef struct FffGrepResult {
    struct FffGrepMatch *items;
    uint32_t count;
    uint32_t total_matched;
    uint32_t total_files_searched;
    uint32_t total_files;
    uint32_t filtered_file_count;
    uint32_t next_file_offset;
    char *regex_fallback_error;
} FffGrepResult;

void fff_destroy(void *fff_handle);

struct FffResult *fff_search(
    void *fff_handle,
    const char *query,
    const char *current_file,
    uint32_t max_threads,
    uint32_t page_index,
    uint32_t page_size,
    int32_t combo_boost_multiplier,
    uint32_t min_combo_count
);

const struct FffFileItem *fff_search_result_get_item(
    const struct FffSearchResult *result,
    uint32_t index
);

const struct FffScore *fff_search_result_get_score(
    const struct FffSearchResult *result,
    uint32_t index
);

void fff_free_search_result(struct FffSearchResult *result);

struct FffResult *fff_search_directories(
    void *fff_handle,
    const char *query,
    const char *current_file,
    uint32_t max_threads,
    uint32_t page_index,
    uint32_t page_size
);

const struct FffDirItem *fff_dir_search_result_get_item(
    const struct FffDirSearchResult *result,
    uint32_t index
);

const struct FffScore *fff_dir_search_result_get_score(
    const struct FffDirSearchResult *result,
    uint32_t index
);

void fff_free_dir_search_result(struct FffDirSearchResult *result);

struct FffResult *fff_search_mixed(
    void *fff_handle,
    const char *query,
    const char *current_file,
    uint32_t max_threads,
    uint32_t page_index,
    uint32_t page_size,
    int32_t combo_boost_multiplier,
    uint32_t min_combo_count
);

const struct FffMixedItem *fff_mixed_search_result_get_item(
    const struct FffMixedSearchResult *result,
    uint32_t index
);

const struct FffScore *fff_mixed_search_result_get_score(
    const struct FffMixedSearchResult *result,
    uint32_t index
);

void fff_free_mixed_search_result(struct FffMixedSearchResult *result);

struct FffResult *fff_live_grep(
    void *fff_handle,
    const char *query,
    uint8_t mode,
    uint64_t max_file_size,
    uint32_t max_matches_per_file,
    bool smart_case,
    uint32_t file_offset,
    uint32_t page_limit,
    uint64_t time_budget_ms,
    uint32_t before_context,
    uint32_t after_context,
    bool classify_definitions
);

const struct FffGrepMatch *fff_grep_result_get_match(
    const struct FffGrepResult *result,
    uint32_t index
);
uint32_t fff_grep_result_get_count(const struct FffGrepResult *result);
const char *fff_grep_match_get_relative_path(const struct FffGrepMatch *match);
const char *fff_grep_match_get_file_name(const struct FffGrepMatch *match);
const char *fff_grep_match_get_line_content(const struct FffGrepMatch *match);
uint64_t fff_grep_match_get_line_number(const struct FffGrepMatch *match);
void fff_free_grep_result(struct FffGrepResult *result);

struct FffResult *fff_get_scan_progress(void *fff_handle);
void fff_free_scan_progress(struct FffScanProgress *result);
struct FffResult *fff_scan_files(void *fff_handle);
struct FffResult *fff_restart_index(void *fff_handle, const char *new_path);
struct FffResult *fff_track_query(void *fff_handle, const char *query, const char *file_path);
void fff_free_result(struct FffResult *result);

#endif
