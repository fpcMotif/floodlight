const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    // Linux links executables as PIE by default, so an archive linked into
    // one (the scriptc frontend) must be position-independent. Mach-O always is.
    const pic = b.option(bool, "pic", "Build position-independent code") orelse false;

    const core = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = if (pic) true else null,
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

    const tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run engine tests").dependOn(&b.addRunArtifact(tests).step);
}
