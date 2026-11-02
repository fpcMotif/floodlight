// The AppKit, ImageIO, Quick Look and CoreGraphics calls MyGo does not
// make for us. Everything returned to Go is malloc'd and freed by Go.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <ImageIO/ImageIO.h>
#import <Quartz/Quartz.h>
#import <QuartzCore/QuartzCore.h>
#import <malloc/malloc.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "platform_darwin.h"

static NSString *const kOwnWrite = @"com.floodlight.own-write";

static char *dupString(NSString *s) {
	if (s == nil) return NULL;
	return strdup(s.UTF8String ?: "");
}

static void *dupData(NSData *d, long *len) {
	*len = 0;
	if (d == nil || d.length == 0) return NULL;
	void *p = malloc(d.length);
	memcpy(p, d.bytes, d.length);
	*len = (long)d.length;
	return p;
}

long fl_pb_change_count(void) {
	return (long)NSPasteboard.generalPasteboard.changeCount;
}

// thumbnail is 128 px on the long side, as the Swift store's: what the
// board's list shows without decoding the full image.
static NSData *thumbnail(NSData *data, int px) {
	CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
	if (src == NULL) return nil;
	NSDictionary *opts = @{
		(__bridge id)kCGImageSourceThumbnailMaxPixelSize: @(px),
		(__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
		(__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
	};
	CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
	CFRelease(src);
	if (cg == NULL) return nil;
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
	CGImageRelease(cg);
	return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

void fl_pb_read(fl_pasteboard *out, long max_text, long max_image, int thumb_px) {
	@autoreleasepool {
		memset(out, 0, sizeof *out);
		NSPasteboard *pb = NSPasteboard.generalPasteboard;
		NSArray<NSPasteboardType> *types = pb.types ?: @[];
		out->types = dupString([types componentsJoinedByString:@"\n"]);

		NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[ NSURL.class ]
		                                           options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
		if (urls.count > 0) {
			NSMutableArray *paths = [NSMutableArray array];
			for (NSURL *u in urls) {
				NSString *p = u.URLByStandardizingPath.path;
				if (p.length > 0) [paths addObject:p];
			}
			out->files = dupString([paths componentsJoinedByString:@"\n"]);
			return;
		}

		NSData *png = [pb dataForType:NSPasteboardTypePNG];
		NSData *tiff = png == nil ? [pb dataForType:NSPasteboardTypeTIFF] : nil;
		NSData *image = png ?: tiff;
		if (image != nil && (long)image.length <= max_image) {
			NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:image];
			if (rep != nil && rep.pixelsWide > 0 && rep.pixelsHigh > 0) {
				NSData *stored = png ?: [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
				out->png = dupData(stored, &out->png_len);
				out->thumb = dupData(thumbnail(stored, thumb_px), &out->thumb_len);
				out->width = (int)rep.pixelsWide;
				out->height = (int)rep.pixelsHigh;
				out->is_tiff = png == nil;
				return;
			}
		}

		// Text over the limit is still handed over, cut to one byte past it:
		// enough for capture to say why it skipped the copy without moving
		// megabytes into Go.
		NSString *text = [pb stringForType:NSPasteboardTypeString];
		if (text != nil) {
			NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
			NSUInteger n = MIN(utf8.length, (NSUInteger)max_text + 1);
			out->text = malloc(n + 1);
			memcpy(out->text, utf8.bytes, n);
			out->text[n] = 0;
		}
	}
}

void fl_pb_free(fl_pasteboard *pb) {
	free(pb->types);
	free(pb->files);
	free(pb->text);
	free(pb->png);
	free(pb->thumb);
	memset(pb, 0, sizeof *pb);
}

static NSPasteboard *beginWrite(void) {
	NSPasteboard *pb = NSPasteboard.generalPasteboard;
	[pb clearContents];
	return pb;
}

// markOwn tags the write so capture skips it: pasting an old entry must
// not record it again.
static void markOwn(NSPasteboard *pb) {
	[pb setString:@"1" forType:kOwnWrite];
}

void fl_pb_write_text(const char *text) {
	@autoreleasepool {
		NSPasteboard *pb = beginWrite();
		[pb setString:[NSString stringWithUTF8String:text] forType:NSPasteboardTypeString];
		markOwn(pb);
	}
}

void fl_pb_write_files(const char *paths) {
	@autoreleasepool {
		NSPasteboard *pb = beginWrite();
		NSMutableArray *urls = [NSMutableArray array];
		for (NSString *p in [[NSString stringWithUTF8String:paths] componentsSeparatedByString:@"\n"]) {
			if (p.length > 0) [urls addObject:[NSURL fileURLWithPath:p]];
		}
		[pb writeObjects:urls];
		markOwn(pb);
	}
}

void fl_pb_write_png(const void *bytes, long len) {
	@autoreleasepool {
		NSPasteboard *pb = beginWrite();
		[pb setData:[NSData dataWithBytes:bytes length:(NSUInteger)len] forType:NSPasteboardTypePNG];
		markOwn(pb);
	}
}

int fl_frontmost_pid(void) {
	return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
}

char *fl_frontmost_bundle(void) {
	return dupString(NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier);
}

char *fl_app_name(const char *bundle_id) {
	@autoreleasepool {
		NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:[NSString stringWithUTF8String:bundle_id]];
		if (url == nil) return NULL;
		return dupString(url.URLByDeletingPathExtension.lastPathComponent);
	}
}

bool fl_ax_trusted(bool prompt) {
	if (!prompt) return AXIsProcessTrusted();
	NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
	return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

// fl_paste_into brings pid forward and types ⌘V into it, as the Swift
// PasteTargetDelivery does. It waits for the activation, so it runs off the
// main thread. False when the app is gone, never comes forward, or a
// password field holds secure input.
bool fl_paste_into(int pid) {
	@autoreleasepool {
		NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
		if (app == nil) return false;
		[app activateWithOptions:0];
		for (int i = 0; !app.isActive; i++) {
			if (i == 40) return false;
			usleep(15000);
		}
		if (IsSecureEventInputEnabled()) return false;
		// The target needs a beat to make its window key after activating.
		usleep(80000);
		CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
		CGEventRef down = CGEventCreateKeyboardEvent(src, (CGKeyCode)kVK_ANSI_V, true);
		CGEventRef up = CGEventCreateKeyboardEvent(src, (CGKeyCode)kVK_ANSI_V, false);
		CGEventSetFlags(down, kCGEventFlagMaskCommand);
		CGEventSetFlags(up, kCGEventFlagMaskCommand);
		CGEventPostToPid(pid, down);
		CGEventPostToPid(pid, up);
		CFRelease(down);
		CFRelease(up);
		if (src) CFRelease(src);
		return true;
	}
}

@interface FLPreviewSource : NSObject <QLPreviewPanelDataSource>
@property(strong) NSURL *url;
@end

@implementation FLPreviewSource
- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel {
	return self.url != nil ? 1 : 0;
}
- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
	return self.url;
}
@end

static FLPreviewSource *previewSource;

void fl_quicklook_toggle(const char *path) {
	@autoreleasepool {
		QLPreviewPanel *panel = QLPreviewPanel.sharedPreviewPanel;
		if (panel.isVisible) {
			[panel orderOut:nil];
			return;
		}
		if (previewSource == nil) previewSource = [FLPreviewSource new];
		previewSource.url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
		panel.dataSource = previewSource;
		[panel reloadData];
		[panel makeKeyAndOrderFront:nil];
	}
}

bool fl_quicklook_visible(void) {
	return QLPreviewPanel.sharedPreviewPanelExists && QLPreviewPanel.sharedPreviewPanel.isVisible;
}

void fl_quicklook_close(void) {
	if (QLPreviewPanel.sharedPreviewPanelExists) [QLPreviewPanel.sharedPreviewPanel orderOut:nil];
	previewSource.url = nil;
}

bool fl_reduce_transparency(void) {
	return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
}

// fl_release_memory hands freed malloc pages back to the system. Go's
// FreeOSMemory covers the Go heap; this covers what AppKit and Metal freed.
void fl_release_memory(void) {
	malloc_zone_pressure_relief(NULL, 0);
}

// fl_settings_window finds System Settings' window, in CGWindowList's
// top-left coordinates, which are MyGo's too.
bool fl_settings_window(double *x, double *y, double *w, double *h) {
	@autoreleasepool {
		CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
		if (list == NULL) return false;
		NSArray *windows = CFBridgingRelease(list);
		for (NSDictionary *info in windows) {
			if ([info[(__bridge id)kCGWindowLayer] intValue] != 0 || [info[(__bridge id)kCGWindowAlpha] doubleValue] <= 0.5) continue;
			NSString *owner = info[(__bridge id)kCGWindowOwnerName];
			if (![owner containsString:@"System Settings"] && ![owner containsString:@"System Preferences"]) continue;
			CGRect r;
			if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(__bridge id)kCGWindowBounds], &r)) continue;
			*x = r.origin.x;
			*y = r.origin.y;
			*w = r.size.width;
			*h = r.size.height;
			return true;
		}
		return false;
	}
}

void fl_open_fda_settings(void) {
	@autoreleasepool {
		for (NSString *s in @[
			     @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
			     @"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
		     ]) {
			NSURL *url = [NSURL URLWithString:s];
			if (url != nil && [NSWorkspace.sharedWorkspace openURL:url]) return;
		}
	}
}

void *fl_icon_png(const char *path, int px, long *len) {
	@autoreleasepool {
		NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:[NSString stringWithUTF8String:path]];
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
		                                                                pixelsWide:px
		                                                                pixelsHigh:px
		                                                             bitsPerSample:8
		                                                           samplesPerPixel:4
		                                                                  hasAlpha:YES
		                                                                  isPlanar:NO
		                                                            colorSpaceName:NSDeviceRGBColorSpace
		                                                               bytesPerRow:0
		                                                              bitsPerPixel:0];
		[NSGraphicsContext saveGraphicsState];
		NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
		[icon drawInRect:NSMakeRect(0, 0, px, px) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
		[NSGraphicsContext restoreGraphicsState];
		return dupData([rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}], len);
	}
}

// fl_configure_panel puts a launcher window at status level over every Space
// and full-screen app, and keeps its drawn frame at the visual top while it
// resizes. Without the gravity, Core Animation scales the last frame to the
// new size until Metal presents one, and the panel shows a stretched bar.
void fl_configure_panel(uintptr_t handle) {
	NSWindow *w = (__bridge NSWindow *)(void *)handle;
	w.level = NSStatusWindowLevel;
	w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
	                       NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
	w.hidesOnDeactivate = NO;
	w.animationBehavior = NSWindowAnimationBehaviorNone;
	NSView *v = w.contentView;
	v.wantsLayer = YES;
	v.layer.contentsGravity = v.isFlipped ? kCAGravityBottom : kCAGravityTop;
	for (NSView *sub in v.subviews) {
		sub.wantsLayer = YES;
		sub.layer.contentsGravity = sub.isFlipped ? kCAGravityBottom : kCAGravityTop;
	}
}
