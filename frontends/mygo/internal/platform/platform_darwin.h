#include <stdbool.h>
#include <stdint.h>

typedef struct {
	char *types;  /* pasteboard types, one per line */
	char *files;  /* file paths, one per line */
	char *text;
	void *png;
	long png_len;
	void *thumb;
	long thumb_len;
	int width, height;
	int is_tiff;
} fl_pasteboard;

long fl_pb_change_count(void);
void fl_pb_read(fl_pasteboard *out, long max_text, long max_image, int thumb_px);
void fl_pb_free(fl_pasteboard *pb);
void fl_pb_write_text(const char *text);
void fl_pb_write_files(const char *paths);
void fl_pb_write_png(const void *bytes, long len);

int fl_frontmost_pid(void);
char *fl_frontmost_bundle(void);
char *fl_app_name(const char *bundle_id);

bool fl_ax_trusted(bool prompt);
bool fl_paste_into(int pid);

void fl_quicklook_toggle(const char *path);
bool fl_quicklook_visible(void);
void fl_quicklook_close(void);

bool fl_reduce_transparency(void);
void fl_release_memory(void);
bool fl_settings_window(double *x, double *y, double *w, double *h);
void fl_open_fda_settings(void);
void *fl_icon_png(const char *path, int px, long *len);
void fl_configure_panel(uintptr_t nswindow);
