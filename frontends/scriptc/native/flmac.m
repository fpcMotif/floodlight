/*
 * The macOS platform layer (flnative.h): the pasteboard, paste delivery,
 * app names, Full Disk Access, and the terminal that hosts this process.
 *
 * Called from the script thread only. Nothing here starts a run loop: the
 * TUI and the capture agent are plain processes, and every call below works
 * without NSApplication.
 */
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <unistd.h>

#include "flnative.h"

#define RS 0x1e
#define US 0x1f

static NSString *const kOwnWrite = @"com.floodlight.own-write";
static const int kThumbnailPixels = 128;

static NSData *pending_png;
static NSData *pending_tiff;
static NSData *pending_thumbnail;

static NSString *span_string(const uint8_t *bytes, size_t len) {
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding] ?: @"";
}

int32_t flm_change_count(void) { return (int32_t)[NSPasteboard generalPasteboard].changeCount; }

static void append(NSMutableData *out, NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) {
        uint8_t b = (p[i] == RS || p[i] == US) ? ' ' : p[i];
        [out appendBytes:&b length:1];
    }
}

static void sep(NSMutableData *out, uint8_t b) { [out appendBytes:&b length:1]; }

/* A 128 px PNG thumbnail, aspect kept, through ImageIO. */
static NSData *thumbnail_png(NSData *data) {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (src == NULL) return nil;
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @(kThumbnailPixels),
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
    };
    CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (thumb == NULL) return nil;
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, CFSTR("public.png"), 1, NULL);
    if (dst != NULL) {
        CGImageDestinationAddImage(dst, thumb, NULL);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(thumb);
    return out.length > 0 ? out : nil;
}

static void image_size(NSData *data, int *w, int *h) {
    *w = 0;
    *h = 0;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (src == NULL) return;
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    CFRelease(src);
    *w = [props[(id)kCGImagePropertyPixelWidth] intValue];
    *h = [props[(id)kCGImagePropertyPixelHeight] intValue];
}

static NSString *sha256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

int32_t flm_read_capture(uint8_t *out, size_t cap) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        NSMutableData *buf = [NSMutableData data];
        NSArray<NSPasteboardType> *types = pb.types ?: @[];
        for (NSUInteger i = 0; i < types.count; i++) {
            if (i > 0) sep(buf, US);
            append(buf, types[i]);
        }
        sep(buf, RS);

        NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[ [NSURL class] ]
                                                   options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
        for (NSUInteger i = 0; i < urls.count; i++) {
            if (i > 0) sep(buf, US);
            append(buf, urls[i].path ?: @"");
        }
        sep(buf, RS);

        NSString *text = [pb stringForType:NSPasteboardTypeString];
        if (urls.count == 0 && text != nil) [buf appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
        sep(buf, RS);

        pending_png = nil;
        pending_tiff = nil;
        pending_thumbnail = nil;
        if (urls.count == 0) {
            pending_png = [pb dataForType:NSPasteboardTypePNG];
            pending_tiff = [pb dataForType:NSPasteboardTypeTIFF];
        }
        NSData *primary = pending_png ?: pending_tiff;
        if (primary.length > 0) {
            int w = 0, h = 0;
            image_size(primary, &w, &h);
            pending_thumbnail = thumbnail_png(primary);
            append(buf, [NSString stringWithFormat:@"%lu", (unsigned long)primary.length]);
            sep(buf, US);
            append(buf, [NSString stringWithFormat:@"%d", w]);
            sep(buf, US);
            append(buf, [NSString stringWithFormat:@"%d", h]);
            sep(buf, US);
            append(buf, sha256(primary));
        }
        sep(buf, RS);

        NSString *source = [NSWorkspace sharedWorkspace].frontmostApplication.bundleIdentifier ?: @"";
        append(buf, source);

        if (buf.length > cap) return -(int32_t)buf.length;
        memcpy(out, buf.bytes, buf.length);
        return (int32_t)buf.length;
    }
}

size_t flm_pending_png(const uint8_t **out) {
    *out = pending_png.bytes;
    return pending_png.length;
}

size_t flm_pending_tiff(const uint8_t **out) {
    *out = pending_tiff.bytes;
    return pending_tiff.length;
}

size_t flm_pending_thumbnail(const uint8_t **out) {
    *out = pending_thumbnail.bytes;
    return pending_thumbnail.length;
}

/* Every write carries the private marker so the capture agent skips it. */
static NSPasteboard *begin_write(NSArray<NSPasteboardType> *types) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb declareTypes:[types arrayByAddingObject:kOwnWrite] owner:nil];
    [pb setData:[NSData data] forType:kOwnWrite];
    return pb;
}

int32_t flm_write_text(const uint8_t *text, size_t len) {
    @autoreleasepool {
        NSPasteboard *pb = begin_write(@[ NSPasteboardTypeString ]);
        return [pb setString:span_string(text, len) forType:NSPasteboardTypeString] ? 1 : -1;
    }
}

int32_t flm_write_file(const uint8_t *path, size_t len) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:span_string(path, len)];
        NSPasteboard *pb = begin_write(@[ NSPasteboardTypeFileURL, NSPasteboardTypeString ]);
        BOOL ok = [pb setString:url.absoluteString forType:NSPasteboardTypeFileURL];
        [pb setString:url.path forType:NSPasteboardTypeString];
        return ok ? 1 : -1;
    }
}

int32_t flm_write_image(const uint8_t *png, size_t png_len, const uint8_t *tiff, size_t tiff_len) {
    @autoreleasepool {
        NSMutableArray<NSPasteboardType> *types = [NSMutableArray array];
        if (png_len > 0) [types addObject:NSPasteboardTypePNG];
        if (tiff_len > 0) [types addObject:NSPasteboardTypeTIFF];
        if (types.count == 0) return -1;
        NSPasteboard *pb = begin_write(types);
        if (png_len > 0) [pb setData:[NSData dataWithBytes:png length:png_len] forType:NSPasteboardTypePNG];
        if (tiff_len > 0) [pb setData:[NSData dataWithBytes:tiff length:tiff_len] forType:NSPasteboardTypeTIFF];
        return 1;
    }
}

/* ⌘V into `pid`. The popup terminal closes as the TUI exits, but the target
 * must be frontmost before the keystroke lands, so activate it first and
 * give WindowServer a moment. Accessibility is asked for once (#66). */
int32_t flm_paste_to(int32_t pid) {
    @autoreleasepool {
        NSDictionary *prompt = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)prompt)) return -EPERM;
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (app == nil) return -ESRCH;
        [app activateWithOptions:NSApplicationActivateAllWindows];
        for (int i = 0; i < 50 && !app.active; i++) usleep(10000);
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
        const CGKeyCode v = 9; /* kVK_ANSI_V */
        CGEventRef down = CGEventCreateKeyboardEvent(source, v, true);
        CGEventRef up = CGEventCreateKeyboardEvent(source, v, false);
        CGEventSetFlags(down, kCGEventFlagMaskCommand);
        CGEventSetFlags(up, kCGEventFlagMaskCommand);
        CGEventPostToPid(pid, down);
        CGEventPostToPid(pid, up);
        CFRelease(down);
        CFRelease(up);
        if (source != NULL) CFRelease(source);
        return 1;
    }
}

int32_t flm_frontmost_pid(void) {
    NSRunningApplication *app = [NSWorkspace sharedWorkspace].frontmostApplication;
    return app == nil ? -1 : (int32_t)app.processIdentifier;
}

static int32_t copy_out(NSString *s, uint8_t *out, size_t cap) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (d.length > cap) return 0;
    memcpy(out, d.bytes, d.length);
    return (int32_t)d.length;
}

int32_t flm_app_name(const uint8_t *bundle_id, size_t len, uint8_t *out, size_t cap) {
    @autoreleasepool {
        NSString *bid = span_string(bundle_id, len);
        if (bid.length == 0) return 0;
        NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bid];
        if (url == nil) return 0;
        return copy_out(url.URLByDeletingPathExtension.lastPathComponent, out, cap);
    }
}

/* The TCC database is readable only with Full Disk Access: a plain open is
 * the cheapest probe, and it prompts nothing. */
int32_t flm_full_disk_access(void) {
    const char *home = getenv("HOME");
    if (home == NULL) return -1;
    char path[1024];
    snprintf(path, sizeof path, "%s/Library/Application Support/com.apple.TCC/TCC.db", home);
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
        close(fd);
        return 1;
    }
    return errno == EPERM || errno == EACCES ? 0 : -1;
}

/* Walks up the parent processes to the first one running from an app
 * bundle: the terminal, which is what TCC grants access to. */
int32_t flm_host_app(uint8_t *out, size_t cap) {
    pid_t pid = getppid();
    for (int depth = 0; depth < 16 && pid > 1; depth++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof path) > 0) {
            char *marker = strstr(path, ".app/Contents/MacOS/");
            if (marker != NULL) {
                size_t n = (size_t)(marker - path) + 4;
                if (n > cap) return 0;
                memcpy(out, path, n);
                return (int32_t)n;
            }
        }
        struct proc_bsdinfo info;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) break;
        pid = (pid_t)info.pbi_ppid;
    }
    return 0;
}
