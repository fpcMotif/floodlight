/*
 * The Cocoa half of floodlight-panel (ADR 0013, #111): a Spotlight-style
 * floating panel whose state and search live in TypeScript.
 *
 * The run loop is inverted. AppKit normally owns the main thread inside
 * -[NSApplication run], but the script thread *is* the main thread, so
 * TypeScript calls flp_wait, which pumps AppKit events until something the
 * script cares about happens (the query changed, a key, the hotkey) and then
 * returns that as a small integer. The script answers by pushing rows back.
 * No script code ever runs inside an AppKit callback, so scriptc's rule that
 * script closures run only on the script thread holds trivially.
 *
 * Everything below is plain C at the boundary: scalars and UTF-8 spans, the
 * same contract as flshim.c.
 */
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>

#include "flpanel.h"

static const CGFloat kWidth = 680;
static const CGFloat kFieldHeight = 52;
static const CGFloat kRowHeight = 40;
static const NSInteger kVisibleRows = 8;
static const CGFloat kIconSize = 24;

/* ---- event queue ------------------------------------------------------ */

static int32_t queue[64];
static int queueHead, queueCount;
static int32_t lastArg = -1;

static void push(int32_t event) {
    /* Repeated query changes collapse: only the newest text matters. */
    if (event == FLP_EV_QUERY) {
        for (int i = 0; i < queueCount; i++) {
            if (queue[(queueHead + i) % 64] == FLP_EV_QUERY) return;
        }
    }
    if (queueCount == 64) return;
    queue[(queueHead + queueCount) % 64] = event;
    queueCount++;
}

static int32_t pop(void) {
    if (queueCount == 0) return FLP_EV_NONE;
    int32_t event = queue[queueHead];
    queueHead = (queueHead + 1) % 64;
    queueCount--;
    return event;
}

/* ---- rows ------------------------------------------------------------- */

@interface FLRow : NSObject
@property int32_t kind;
@property(copy) NSString *title;
@property(copy) NSString *detail;
@property(copy) NSString *path;
@property(copy) NSIndexSet *marks;
@end
@implementation FLRow
@end

@class FLPanel;
static FLPanel *panel;
static NSTextField *field;
static NSMutableArray<FLRow *> *rows;
static NSInteger selected;
static NSCache<NSString *, NSImage *> *icons;

@interface FLRowsView : NSView
@property NSInteger top;
@end

static FLRowsView *rowsView;

/* ---- panel ------------------------------------------------------------ */

@interface FLPanel : NSPanel
@end
@implementation FLPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
/* Clicking anywhere else dismisses, the way Spotlight does. */
- (void)resignKeyWindow {
    [super resignKeyWindow];
    if (self.visible) push(FLP_EV_HIDDEN);
}
@end

@interface FLFieldDelegate : NSObject <NSTextFieldDelegate>
@end
@implementation FLFieldDelegate
- (void)controlTextDidChange:(NSNotification *)note {
    (void)note;
    push(FLP_EV_QUERY);
}
- (BOOL)control:(NSControl *)control textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    (void)control;
    (void)tv;
    if (sel == @selector(moveUp:)) push(FLP_EV_UP);
    else if (sel == @selector(moveDown:)) push(FLP_EV_DOWN);
    else if (sel == @selector(insertNewline:)) {
        BOOL command = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagCommand) != 0;
        push(command ? FLP_EV_REVEAL : FLP_EV_ENTER);
    } else if (sel == @selector(cancelOperation:)) push(FLP_EV_ESCAPE);
    else return NO;
    return YES;
}
@end

static FLFieldDelegate *fieldDelegate;

@implementation FLRowsView
- (BOOL)isFlipped { return YES; }

- (NSImage *)iconFor:(FLRow *)row {
    NSImage *icon = [icons objectForKey:row.path];
    if (icon == nil) {
        icon = [[NSWorkspace sharedWorkspace] iconForFile:row.path];
        icon.size = NSMakeSize(kIconSize, kIconSize);
        [icons setObject:icon forKey:row.path];
    }
    return icon;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSFont *titleFont = [NSFont systemFontOfSize:15];
    NSFont *boldFont = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSFont *detailFont = [NSFont systemFontOfSize:12];
    NSMutableParagraphStyle *head = [[NSMutableParagraphStyle alloc] init];
    head.lineBreakMode = NSLineBreakByTruncatingHead;
    head.alignment = NSTextAlignmentRight;
    NSMutableParagraphStyle *tail = [[NSMutableParagraphStyle alloc] init];
    tail.lineBreakMode = NSLineBreakByTruncatingTail;

    NSInteger end = MIN((NSInteger)rows.count, self.top + kVisibleRows);
    for (NSInteger i = self.top; i < end; i++) {
        FLRow *row = rows[(NSUInteger)i];
        NSRect r = NSMakeRect(8, (CGFloat)(i - self.top) * kRowHeight, kWidth - 16, kRowHeight);
        BOOL isSelected = i == selected;
        if (isSelected) {
            [[NSColor.controlAccentColor colorWithAlphaComponent:0.85] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0, 2) xRadius:8 yRadius:8] fill];
        }
        NSColor *primary = isSelected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor;
        NSColor *secondary = isSelected ? [primary colorWithAlphaComponent:0.75] : NSColor.secondaryLabelColor;

        NSImage *icon = [self iconFor:row];
        [icon drawInRect:NSMakeRect(r.origin.x + 10, NSMidY(r) - kIconSize / 2, kIconSize, kIconSize)];

        CGFloat detailWidth = MIN(260, (r.size.width - 60) / 2);
        NSMutableAttributedString *title = [[NSMutableAttributedString alloc]
            initWithString:row.title
                attributes:@{NSFontAttributeName : titleFont, NSForegroundColorAttributeName : primary,
                             NSParagraphStyleAttributeName : tail}];
        [row.marks enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            (void)stop;
            if (idx < title.length) [title addAttribute:NSFontAttributeName value:boldFont range:NSMakeRange(idx, 1)];
        }];
        NSRect titleRect = NSMakeRect(r.origin.x + 44, NSMidY(r) - 10, r.size.width - 60 - detailWidth, 20);
        [title drawWithRect:titleRect
                   options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                   context:nil];

        NSRect detailRect = NSMakeRect(NSMaxX(r) - detailWidth - 12, NSMidY(r) - 8, detailWidth, 16);
        [row.detail drawWithRect:detailRect
                         options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                      attributes:@{NSFontAttributeName : detailFont, NSForegroundColorAttributeName : secondary,
                                   NSParagraphStyleAttributeName : head}
                         context:nil];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger i = self.top + (NSInteger)(p.y / kRowHeight);
    if (i < 0 || i >= (NSInteger)rows.count) return;
    lastArg = (int32_t)i;
    push(event.clickCount >= 2 ? FLP_EV_OPEN_INDEX : FLP_EV_SELECT_INDEX);
}
@end

/* ---- layout ----------------------------------------------------------- */

static void keepSelectionVisible(void) {
    if (selected < rowsView.top) rowsView.top = selected;
    if (selected >= rowsView.top + kVisibleRows) rowsView.top = selected - kVisibleRows + 1;
    if (rowsView.top < 0) rowsView.top = 0;
}

static void layout(void) {
    NSInteger shown = MIN((NSInteger)rows.count, kVisibleRows);
    CGFloat listHeight = shown > 0 ? (CGFloat)shown * kRowHeight + 10 : 0;
    CGFloat height = kFieldHeight + listHeight;
    NSRect frame = panel.frame;
    /* Grow downward: the field stays put under the user's eye. */
    CGFloat top = NSMaxY(frame);
    [panel setFrame:NSMakeRect(frame.origin.x, top - height, kWidth, height) display:NO];
    field.frame = NSMakeRect(20, height - kFieldHeight + 10, kWidth - 40, 32);
    rowsView.frame = NSMakeRect(0, 0, kWidth, listHeight);
    rowsView.needsDisplay = YES;
}

static void placeOnActiveScreen(void) {
    NSScreen *screen = NSScreen.mainScreen;
    NSPoint mouse = NSEvent.mouseLocation;
    for (NSScreen *s in NSScreen.screens) {
        if (NSPointInRect(mouse, s.frame)) screen = s;
    }
    NSRect visible = screen.visibleFrame;
    CGFloat x = NSMidX(visible) - kWidth / 2;
    CGFloat top = NSMaxY(visible) - visible.size.height * 0.22;
    [panel setFrame:NSMakeRect(x, top - kFieldHeight, kWidth, kFieldHeight) display:NO];
}

/* ---- hotkey ----------------------------------------------------------- */

static OSStatus onHotKey(EventHandlerCallRef next, EventRef event, void *context) {
    (void)next;
    (void)event;
    (void)context;
    push(FLP_EV_HOTKEY);
    return noErr;
}

/* ---- C surface -------------------------------------------------------- */

int32_t flp_start(int32_t hotkey) {
    if (!NSThread.isMainThread) return -1;
    [NSApplication sharedApplication];
    /* No Dock icon, no menu bar: a launcher, not an app you switch to. */
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];

    rows = [NSMutableArray array];
    icons = [[NSCache alloc] init];
    icons.countLimit = 64;

    panel = [[FLPanel alloc] initWithContentRect:NSMakeRect(0, 0, kWidth, kFieldHeight)
                                       styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel |
                                                 NSWindowStyleMaskFullSizeContentView
                                         backing:NSBackingStoreBuffered
                                           defer:YES];
    panel.level = NSPopUpMenuWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;

    NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kFieldHeight)];
    blur.material = NSVisualEffectMaterialPopover;
    blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    blur.state = NSVisualEffectStateActive;
    blur.wantsLayer = YES;
    blur.layer.cornerRadius = 14;
    blur.layer.masksToBounds = YES;
    blur.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    panel.contentView = blur;

    field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.font = [NSFont systemFontOfSize:24 weight:NSFontWeightLight];
    field.placeholderString = @"Floodlight Search";
    field.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    fieldDelegate = [[FLFieldDelegate alloc] init];
    field.delegate = fieldDelegate;
    [blur addSubview:field];

    rowsView = [[FLRowsView alloc] initWithFrame:NSZeroRect];
    [blur addSubview:rowsView];
    placeOnActiveScreen();
    layout();

    if (hotkey) {
        EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
        InstallApplicationEventHandler(NewEventHandlerUPP(onHotKey), 1, &spec, NULL, NULL);
        EventHotKeyRef ref;
        EventHotKeyID hotKeyID = {0x464C444C /* FLDL */, 1};
        /* ⌥Space: ⌘Space stays Spotlight's unless the user moves it. */
        if (RegisterEventHotKey(kVK_Space, optionKey, hotKeyID, GetApplicationEventTarget(), 0, &ref) != noErr) return -2;
    }
    return 1;
}

int32_t flp_wait(int32_t timeout_ms) {
    @autoreleasepool {
        int32_t ready = pop();
        if (ready != FLP_EV_NONE) return ready;
        NSDate *deadline = timeout_ms < 0 ? NSDate.distantFuture : [NSDate dateWithTimeIntervalSinceNow:timeout_ms / 1000.0];
        for (;;) {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:deadline
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event == nil) return FLP_EV_NONE;
            [NSApp sendEvent:event];
            [NSApp updateWindows];
            ready = pop();
            if (ready != FLP_EV_NONE) return ready;
        }
    }
}

int32_t flp_event_arg(void) { return lastArg; }

uint32_t flp_query(uint8_t *out, size_t cap) {
    const char *utf8 = field.stringValue.UTF8String;
    size_t len = utf8 == NULL ? 0 : strlen(utf8);
    if (len > cap) return 0;
    memcpy(out, utf8, len);
    return (uint32_t)len;
}

void flp_clear_rows(void) { [rows removeAllObjects]; }

static NSString *string(const uint8_t *bytes, size_t len) {
    NSString *s = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    return s == nil ? @"" : s;
}

void flp_add_row(int32_t kind, const uint8_t *title, size_t title_len, const uint8_t *detail, size_t detail_len,
                 const uint8_t *path, size_t path_len, const uint8_t *marks, size_t marks_len) {
    FLRow *row = [[FLRow alloc] init];
    row.kind = kind;
    row.title = string(title, title_len);
    row.detail = string(detail, detail_len);
    row.path = string(path, path_len);
    /* Marks arrive as comma-separated UTF-16 offsets, NSString's own units. */
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSString *part in [string(marks, marks_len) componentsSeparatedByString:@","]) {
        if (part.length > 0) [set addIndex:(NSUInteger)part.integerValue];
    }
    row.marks = set;
    [rows addObject:row];
}

void flp_commit(int32_t selection) {
    selected = selection;
    keepSelectionVisible();
    layout();
    /* Draw now rather than at the end of the run-loop pass: the frame the
     * user waits for is this one, and it makes the latency measurable. */
    if (panel.visible) {
        [panel displayIfNeeded];
        [CATransaction flush];
    }
}

void flp_select(int32_t selection) {
    selected = selection;
    keepSelectionVisible();
    rowsView.needsDisplay = YES;
}

/* Returns ms from the call to the frame being on screen, so the script can
 * report summon latency without guessing at the compositor. */
double flp_show(void) {
    CFTimeInterval start = CACurrentMediaTime();
    if (!panel.visible) {
        placeOnActiveScreen();
        layout();
    }
    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:field];
    [panel displayIfNeeded];
    [CATransaction flush];
    return (CACurrentMediaTime() - start) * 1000.0;
}

void flp_hide(void) {
    [panel orderOut:nil];
    field.stringValue = @"";
    [rows removeAllObjects];
    /* Icons are the panel's biggest allocation; a hidden launcher keeps none. */
    [icons removeAllObjects];
    rowsView.top = 0;
    layout();
    /* orderOut also resigns key, which queued a HIDDEN for a hide the script
     * itself asked for; drop it. */
    queueCount = 0;
}

uint8_t flp_visible(void) { return panel.visible ? 1 : 0; }
