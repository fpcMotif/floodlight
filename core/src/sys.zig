//! The few syscalls the engine makes, called directly.
//!
//! `posix.system` is the raw Linux syscall table on Linux (no libc linked)
//! and libSystem on macOS. Going through it rather than `std.Io` keeps the
//! engine free of an event-loop handle it would never use: every call here is
//! one blocking syscall on a path that is already off the main thread.

const std = @import("std");
const posix = std.posix;
const system = posix.system;

pub const fd_t = posix.fd_t;
pub const cwd: fd_t = posix.AT.FDCWD;

pub const Error = error{
    FileNotFound,
    AccessDenied,
    NotDir,
    IsDir,
    PathAlreadyExists,
    NoSpaceLeft,
    NameTooLong,
    OutOfMemory,
    Unexpected,
};

fn fail(e: posix.E) Error {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .EXIST => error.PathAlreadyExists,
        .NOSPC, .DQUOT => error.NoSpaceLeft,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

fn zpath(path: []const u8, buf: *[posix.PATH_MAX:0]u8) Error![*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf;
}

pub const OpenMode = enum { read, dir, create };

pub fn openat(dir: fd_t, path: []const u8, mode: OpenMode) Error!fd_t {
    const flags: posix.O = switch (mode) {
        .read => .{ .CLOEXEC = true },
        // NOFOLLOW so a symlinked folder is indexed as a plain entry, never walked:
        // a link loop would otherwise recurse until max_depth.
        .dir => .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true },
        .create => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
    };
    return posix.openat(dir, path, flags, 0o644) catch |e| mapOpenError(e);
}

/// Opens the root of a scan, which unlike its children may be a symlink
/// (`/tmp` on macOS is one).
pub fn openRoot(path: []const u8) Error!fd_t {
    return posix.openat(cwd, path, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch |e| mapOpenError(e);
}

fn mapOpenError(e: posix.OpenError) Error {
    return switch (e) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.NotDir => error.NotDir,
        error.IsDir => error.IsDir,
        error.PathAlreadyExists => error.PathAlreadyExists,
        error.NameTooLong => error.NameTooLong,
        error.NoSpaceLeft => error.NoSpaceLeft,
        else => error.Unexpected,
    };
}

pub fn close(fd: fd_t) void {
    _ = system.close(fd);
}

pub fn pwriteAll(fd: fd_t, bytes: []const u8, offset: u64) Error!void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = system.pwrite(fd, bytes.ptr + done, bytes.len - done, @intCast(offset + done));
        switch (posix.errno(rc)) {
            .SUCCESS => done += @intCast(rc),
            .INTR => continue,
            else => |e| return fail(e),
        }
    }
}

pub fn ftruncate(fd: fd_t, len: u64) Error!void {
    while (true) switch (posix.errno(system.ftruncate(fd, @intCast(len)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |e| return fail(e),
    };
}

pub fn size(fd: fd_t) Error!u64 {
    const rc = system.lseek(fd, 0, posix.SEEK.END);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |e| fail(e),
    };
}

pub fn renameat(dir: fd_t, old: []const u8, new: []const u8) Error!void {
    var a: [posix.PATH_MAX:0]u8 = undefined;
    var b: [posix.PATH_MAX:0]u8 = undefined;
    switch (posix.errno(system.renameat(dir, try zpath(old, &a), dir, try zpath(new, &b)))) {
        .SUCCESS => {},
        else => |e| return fail(e),
    }
}

pub fn unlinkat(dir: fd_t, path: []const u8) void {
    var a: [posix.PATH_MAX:0]u8 = undefined;
    _ = system.unlinkat(dir, zpath(path, &a) catch return, 0);
}

pub fn mmapRead(fd: fd_t, len: usize) Error![]align(std.heap.page_size_min) const u8 {
    return posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        else => error.Unexpected,
    };
}

pub fn munmap(bytes: []align(std.heap.page_size_min) const u8) void {
    posix.munmap(bytes);
}

pub fn pid() i32 {
    return @intCast(system.getpid());
}

pub fn monotonicNs() u64 {
    var ts: posix.timespec = undefined;
    _ = system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "a mapping larger than the address space reports OutOfMemory" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "f", .data = "x" });
    const fd = try openat(tmp.dir.handle, "f", .read);
    defer close(fd);
    try t.expectError(error.OutOfMemory, mmapRead(fd, std.math.maxInt(usize) / 2));
}
