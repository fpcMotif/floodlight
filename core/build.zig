const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const core = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // getattrlistbulk comes from libSystem; Linux needs no libc at all.
        .link_libc = target.result.os.tag == .macos,
    });

    // What the Swift shell links: one static archive plus the header.
    const lib = b.addLibrary(.{
        .name = "floodlight_core",
        .linkage = .static,
        .root_module = core,
    });
    b.installArtifact(lib);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(
        b.path("include/floodlight_core.h"),
        "floodlight_core.h",
    ).step);

    const exe = b.addExecutable(.{
        .name = "flcore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag == .macos,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run flcore").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run engine tests").dependOn(&b.addRunArtifact(tests).step);
}
