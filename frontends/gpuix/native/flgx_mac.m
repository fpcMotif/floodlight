/*
 * The window half of the platform layer on macOS (flgx.h).
 *
 * GPUIX opens a GPUI window of class GPUIWindow: an NSWindow subclass whose
 * content view holds GPUI's Metal view (GPUIView). GPUI also registers
 * GPUIPanel, the same subclass of NSPanel with the same single ivar. Swapping
 * the window's class to GPUIPanel and adding the non-activating style is what
 * lets the panel take keys without activating Floodlight, so the app the user
 * came from keeps its state and can receive a paste. The swap is guarded by
 * the instance sizes: if a GPUI update ever gives the two classes different
 * layouts, the swap is refused and the panel activates the app instead.
 */
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <malloc/malloc.h>
#include <string.h>

#include "flgx.h"

static const UInt32 kHotKeySignature = 0x464C4458; /* FLDX */
static const CGFloat kCornerRadius = 30;           /* FloodlightMetrics.cornerRadius */

static NSWindow *panel;
static BOOL nonactivating;
static NSView *materialView;
static int32_t queue[16];
static int queueCount;

static void push(int32_t event) {
    if (queueCount < (int)(sizeof queue / sizeof queue[0])) queue[queueCount++] = event;
}

static int32_t pop(void) {
    if (queueCount == 0) return FLG_EV_NONE;
    int32_t event = queue[0];
    memmove(queue, queue + 1, (size_t)(queueCount - 1) * sizeof queue[0]);
    queueCount--;
    return event;
}

static NSString *span_string(const uint8_t *bytes, size_t len) {
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding] ?: @"";
}

/* ---- hotkeys ---------------------------------------------------------- */

static OSStatus on_hotkey(EventHandlerCallRef next, EventRef event, void *context) {
    (void)next;
    (void)context;
    EventHotKeyID hotKeyID;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof hotKeyID, NULL,
                          &hotKeyID) != noErr) {
        return eventNotHandledErr;
    }
    if (hotKeyID.signature != kHotKeySignature) return eventNotHandledErr;
    push((int32_t)hotKeyID.id);
    return noErr;
}

static int32_t register_hotkey(UInt32 keyCode, UInt32 modifiers, UInt32 eventId) {
    EventHotKeyRef ref;
    EventHotKeyID hotKeyID = {kHotKeySignature, eventId};
    return RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr;
}

int32_t flg_start(void) {
    if (!NSThread.isMainThread) return -1;
    /* No Dock icon, no menu bar: a launcher, not an app you switch to. */
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(NewEventHandlerUPP(on_hotkey), 1, &spec, NULL, NULL);
    /* ⌥Space and ⌥⇧C while the Swift app holds ⌘Space and ⇧⌘C. Carbon needs
     * no Accessibility prompt, unlike an event tap. */
    int32_t registered = 0;
    if (register_hotkey(kVK_Space, optionKey, FLG_EV_HOTKEY_SEARCH)) registered |= 1;
    if (register_hotkey(kVK_ANSI_C, optionKey | shiftKey, FLG_EV_HOTKEY_BOARD)) registered |= 2;

    void (^appearance)(NSNotification *) = ^(NSNotification *note) {
        (void)note;
        push(FLG_EV_APPEARANCE);
    };
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:appearance];
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"AppleInterfaceThemeChangedNotification"
                                                               object:nil
                                                                queue:nil
                                                           usingBlock:appearance];
    return registered;
}

void flg_post_hotkey(int32_t event) { push(event); }

/* ---- the panel -------------------------------------------------------- */

static NSView *gpui_view(void) {
    for (NSView *view in panel.contentView.subviews) {
        if (strcmp(object_getClassName(view), "GPUIView") == 0) return view;
    }
    return nil;
}

static BOOL swap_to_panel_class(NSWindow *window) {
    Class from = object_getClass(window);
    Class to = objc_getClass("GPUIPanel");
    if (to == Nil || strcmp(class_getName(from), "GPUIWindow") != 0) return NO;
    if (class_getInstanceSize(from) != class_getInstanceSize(to)) return NO;
    object_setClass(window, to);
    return YES;
}

int32_t flg_adopt_window(void) {
    if (panel != nil) return nonactivating ? 2 : 1;
    NSArray<NSWindow *> *windows = NSApp.windows;
    if (windows.count == 0) return -1;
    /* GPUIX opens its window on a later run-loop pass than render(), so the
     * caller retries; any window holding GPUI's view is the one. */
    NSWindow *found = nil;
    for (NSWindow *window in windows) {
        for (NSView *view in window.contentView.subviews) {
            if (strcmp(object_getClassName(view), "GPUIView") == 0) found = window;
        }
        if (found == nil && strncmp(object_getClassName(window), "GPUI", 4) == 0) found = window;
        if (found != nil) break;
    }
    if (found == nil && windows.count == 1) found = windows.firstObject;
    if (found == nil) return -2;
    panel = found;

    nonactivating = swap_to_panel_class(panel);
    NSWindowStyleMask mask = NSWindowStyleMaskBorderless | NSWindowStyleMaskFullSizeContentView;
    if (nonactivating) mask |= NSWindowStyleMaskNonactivatingPanel;
    panel.styleMask = mask;
    if (nonactivating) {
        NSPanel *p = (NSPanel *)panel;
        p.floatingPanel = YES;
        p.becomesKeyOnlyIfNeeded = NO;
    }
    panel.level = NSStatusWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient;
    panel.hidesOnDeactivate = NO;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.movable = NO;

    /* A frame drawn at the old size is cropped from the top, never scaled. */
    NSView *view = gpui_view();
    view.wantsLayer = YES;
    view.layer.contentsGravity = kCAGravityTop;

    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResignKeyNotification
                                                    object:panel
                                                     queue:nil
                                                usingBlock:^(NSNotification *note) {
                                                    (void)note;
                                                    if (panel.alphaValue > 0) push(FLG_EV_RESIGNED);
                                                }];
    [panel orderOut:nil];
    return nonactivating ? 2 : 1;
}

int32_t flg_dark(void) {
    NSAppearanceName name =
        [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [name isEqualToString:NSAppearanceNameDarkAqua] ? 1 : 0;
}

int32_t flg_apply_material(void) {
    if (panel == nil) return FLG_MATERIAL_SOLID;
    NSView *content = panel.contentView;
    NSView *view = gpui_view();
    [materialView removeFromSuperview];
    materialView = nil;

    content.wantsLayer = YES;
    content.layer.cornerRadius = kCornerRadius;
    content.layer.cornerCurve = kCACornerCurveContinuous;
    content.layer.masksToBounds = YES;

    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency) return FLG_MATERIAL_SOLID;

    NSView *material = nil;
    int32_t kind = FLG_MATERIAL_BLUR;
#if defined(__MAC_26_0) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_26_0
    if (@available(macOS 26.0, *)) {
        /* Clear by decision (#94), as in the Swift panel: nothing is painted
         * over the slab to make content legible. */
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:content.bounds];
        glass.style = NSGlassEffectViewStyleClear;
        glass.cornerRadius = kCornerRadius;
        material = glass;
        kind = FLG_MATERIAL_GLASS;
    }
#endif
    if (material == nil) {
        NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:content.bounds];
        blur.material = NSVisualEffectMaterialPopover;
        blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        blur.state = NSVisualEffectStateActive;
        material = blur;
    }
    /* The same place GPUI puts its own blurred backdrop: under its view. */
    material.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:material positioned:NSWindowBelow relativeTo:view];
    materialView = material;
    return kind;
}

void flg_set_size(double width, double height) {
    if (panel == nil) return;
    NSRect frame = panel.frame;
    if (fabs(frame.size.width - width) < 0.5 && fabs(frame.size.height - height) < 0.5) return;
    NSRect next = NSMakeRect(NSMidX(frame) - width / 2, NSMaxY(frame) - height, width, height);
    [panel setFrame:next display:YES animate:NO];
}

static void order_front(void) {
    panel.alphaValue = 1;
    if (nonactivating) {
        [panel orderFrontRegardless];
        [panel makeKeyWindow];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
        [panel makeKeyAndOrderFront:nil];
    }
}

double flg_show(double width, double height) {
    if (panel == nil) return -1;
    CFTimeInterval start = CACurrentMediaTime();
    NSPoint mouse = NSEvent.mouseLocation;
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSMouseInRect(mouse, candidate.frame, NO)) {
            screen = candidate;
            break;
        }
    }
    NSRect visible = screen.visibleFrame;
    /* The Swift panel's spot: its 60 pt bar centred 68% of the way up. */
    CGFloat barTop = NSMinY(visible) + NSHeight(visible) * 0.68 + 30;
    NSRect frame = NSMakeRect(NSMidX(visible) - width / 2, barTop - height, width, height);
    [panel setFrame:frame display:NO animate:NO];
    order_front();
    return (CACurrentMediaTime() - start) * 1000.0;
}

void flg_show_at(double x, double y, double width, double height) {
    if (panel == nil) return;
    CGFloat mainHeight = NSHeight(NSScreen.screens.firstObject.frame);
    [panel setFrame:NSMakeRect(x, mainHeight - y - height, width, height) display:NO animate:NO];
    order_front();
}

void flg_hide(void) {
    if (panel == nil) return;
    panel.alphaValue = 0;
}

void flg_order_out(void) {
    if (panel == nil || panel.alphaValue > 0) return;
    [panel orderOut:nil];
    // An activating fallback panel made Floodlight active; hand activation back.
    if (!nonactivating) [NSApp hide:nil];
}

uint8_t flg_visible(void) { return panel != nil && panel.visible && panel.alphaValue > 0 ? 1 : 0; }

/* ---- the run loop while hidden ---------------------------------------- */

int32_t flg_wait(int32_t timeout_ms) {
    @autoreleasepool {
        int32_t ready = pop();
        if (ready != FLG_EV_NONE) return ready;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_ms / 1000.0];
        for (;;) {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:deadline
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event == nil) return FLG_EV_NONE;
            [NSApp sendEvent:event];
            ready = pop();
            if (ready != FLG_EV_NONE) return ready;
        }
    }
}

int32_t flg_next_event(void) { return pop(); }

/* ---- workspace -------------------------------------------------------- */

int32_t flg_open(const uint8_t *target, size_t len, int32_t reveal) {
    @autoreleasepool {
        NSString *s = span_string(target, len);
        if (s.length == 0) return -1;
        NSWorkspace *ws = NSWorkspace.sharedWorkspace;
        BOOL isPath = [s hasPrefix:@"/"];
        NSURL *url = isPath ? [NSURL fileURLWithPath:s] : [NSURL URLWithString:s];
        if (url == nil) return -1;
        if (reveal) {
            if (!isPath) return -1;
            [ws activateFileViewerSelectingURLs:@[ url ]];
            return 1;
        }
        return [ws openURL:url] ? 1 : 0;
    }
}

int32_t flg_icon(const uint8_t *path, size_t path_len, const uint8_t *out, size_t out_len, int32_t size) {
    @autoreleasepool {
        NSString *source = span_string(path, path_len);
        NSString *dest = span_string(out, out_len);
        if ([NSFileManager.defaultManager fileExistsAtPath:dest]) return 1;
        NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:source];
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                        pixelsWide:size
                                                                        pixelsHigh:size
                                                                     bitsPerSample:8
                                                                   samplesPerPixel:4
                                                                          hasAlpha:YES
                                                                          isPlanar:NO
                                                                    colorSpaceName:NSCalibratedRGBColorSpace
                                                                       bytesPerRow:0
                                                                      bitsPerPixel:0];
        if (icon == nil || rep == nil) return 0;
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [icon drawInRect:NSMakeRect(0, 0, size, size)
                fromRect:NSZeroRect
               operation:NSCompositingOperationCopy
                fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return [png writeToFile:dest atomically:YES] ? 1 : 0;
    }
}

int32_t flg_settings_frame(uint8_t *out, size_t cap) {
    if (cap < 4 * sizeof(double)) return 0;
    @autoreleasepool {
        CFArrayRef list =
            CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                       kCGNullWindowID);
        if (list == NULL) return 0;
        int32_t found = 0;
        for (NSDictionary *info in (__bridge NSArray *)list) {
            if (![info[(id)kCGWindowOwnerName] isEqual:@"System Settings"]) continue;
            if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
            CGRect rect;
            if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &rect)) {
                continue;
            }
            double v[4] = {rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
            memcpy(out, v, sizeof v);
            found = 1;
            break;
        }
        CFRelease(list);
        return found;
    }
}

/* ---- the drag source for the Full Disk Access list --------------------- */

@interface FLDragView : NSView <NSDraggingSource>
@property(copy) NSString *path;
@end

@implementation FLDragView
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session;
    (void)context;
    return NSDragOperationCopy | NSDragOperationLink | NSDragOperationGeneric;
}

- (void)mouseDown:(NSEvent *)event {
    NSURL *url = [NSURL fileURLWithPath:self.path];
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
    [item setDraggingFrame:self.bounds contents:[NSWorkspace.sharedWorkspace iconForFile:self.path]];
    [self beginDraggingSessionWithItems:@[ item ] event:event source:self];
}
@end

static FLDragView *dragView;

int32_t flg_drag_source(double x, double y, double width, double height, const uint8_t *path, size_t len) {
    [dragView removeFromSuperview];
    dragView = nil;
    if (panel == nil || width <= 0) return 0;
    NSView *content = panel.contentView;
    NSRect frame = NSMakeRect(x, NSHeight(content.bounds) - y - height, width, height);
    dragView = [[FLDragView alloc] initWithFrame:frame];
    dragView.path = span_string(path, len);
    [content addSubview:dragView positioned:NSWindowAbove relativeTo:gpui_view()];
    return 1;
}

void flg_release_memory(void) { malloc_zone_pressure_relief(NULL, 0); }
