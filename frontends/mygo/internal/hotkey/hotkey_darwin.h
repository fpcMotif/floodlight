#include <stdint.h>

int fl_hotkey_register(uint32_t key_code, uint32_t modifiers, uint32_t id, void **out_ref);
void fl_hotkey_unregister(void *ref);
void fl_hotkey_post(uint32_t key_code, uint64_t flags);
