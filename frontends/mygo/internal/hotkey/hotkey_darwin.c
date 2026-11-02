#include <Carbon/Carbon.h>
#include <ApplicationServices/ApplicationServices.h>

#include "hotkey_darwin.h"

extern void flHotKeyPressed(uint32_t id);

/* 'FlGo': tells our hot keys from MyGo's ('MyGo') and anyone else's. */
static const OSType kSignature = 0x466C476F;

static OSStatus fl_handler(EventHandlerCallRef next, EventRef event, void *data) {
	EventHotKeyID hk;
	OSStatus st = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
		NULL, sizeof hk, NULL, &hk);
	if (st != noErr || hk.signature != kSignature) {
		return eventNotHandledErr;
	}
	flHotKeyPressed(hk.id);
	return noErr;
}

int fl_hotkey_register(uint32_t key_code, uint32_t modifiers, uint32_t id, void **out_ref) {
	static EventHandlerRef handler;
	if (handler == NULL) {
		EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
		OSStatus st = InstallEventHandler(GetApplicationEventTarget(), fl_handler, 1, &spec, NULL, &handler);
		if (st != noErr) {
			return (int)st;
		}
	}
	EventHotKeyID hk = { kSignature, id };
	EventHotKeyRef ref = NULL;
	OSStatus st = RegisterEventHotKey(key_code, modifiers, hk, GetApplicationEventTarget(), 0, &ref);
	*out_ref = ref;
	return (int)st;
}

void fl_hotkey_unregister(void *ref) {
	if (ref != NULL) {
		UnregisterEventHotKey((EventHotKeyRef)ref);
	}
}

void fl_hotkey_post(uint32_t key_code, uint64_t flags) {
	CGEventRef down = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key_code, true);
	CGEventRef up = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key_code, false);
	CGEventSetFlags(down, (CGEventFlags)flags);
	CGEventSetFlags(up, (CGEventFlags)flags);
	CGEventPost(kCGHIDEventTap, down);
	CGEventPost(kCGHIDEventTap, up);
	CFRelease(down);
	CFRelease(up);
}
