const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    // The engine is imported as Zig source, not through the C ABI: one
    // compilation unit, so search inlines into the panel.
    const core = b.createModule(.{
        .root_source_file = b.path("../../core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "nanoui", .module = nanoui },
        .{ .name = "floodlight_core", .module = core },
    };

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    linkSystem(app);
    const exe = b.addExecutable(.{ .name = "floodlight-nanoui", .root_module = app });
    b.installArtifact(exe);

    // A bundle, so Full Disk Access has an app to list and the drag has one to carry.
    const bundle = b.addWriteFiles();
    _ = bundle.addCopyFile(exe.getEmittedBin(), "Floodlight Nano.app/Contents/MacOS/floodlight-nanoui");
    _ = bundle.addCopyFile(b.path("Info.plist"), "Floodlight Nano.app/Contents/Info.plist");
    const install_bundle = b.addInstallDirectory(.{ .source_dir = bundle.getDirectory(), .install_dir = .prefix, .install_subdir = "" });
    // TCC keys Full Disk Access to the signature: the linker's ad-hoc one
    // names the binary, not the bundle, and binds no Info.plist.
    const identity = b.option([]const u8, "sign-identity", "codesign identity for the bundle (ad hoc by default)") orelse "-";
    const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", identity, "--identifier", "com.floodlight.nano" });
    const ad_hoc_requirement_naming_bundle_not_cdhash: []const []const u8 = &.{ "--requirements", "=designated => identifier \"com.floodlight.nano\"" };
    if (std.mem.eql(u8, identity, "-")) sign.addArgs(ad_hoc_requirement_naming_bundle_not_cdhash);
    sign.addDirectoryArg(b.graph.path(.install_prefix, "Floodlight Nano.app"));
    sign.step.dependOn(&install_bundle.step);
    sign.has_side_effects = true;
    b.step("bundle", "Build and sign zig-out/Floodlight Nano.app").dependOn(&sign.step);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the panel (⌥Space shows it)").dependOn(&run.step);

    // Views render offscreen through ui.Tester: no window opens.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    linkSystem(test_module);
    const tests = b.addTest(.{ .root_module = test_module });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);

    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    bench_module.linkFramework("Carbon", .{});
    bench_module.linkFramework("ImageIO", .{});
    bench_module.linkFramework("Quartz", .{});
    bench_module.linkSystemLibrary("sqlite3", .{});
    const bench = b.addExecutable(.{ .name = "floodlight-nanoui-bench", .root_module = bench_module });
    b.step("bench", "Run the in-process latency benchmark").dependOn(&b.addRunArtifact(bench).step);
}

/// What the app and its tests both link from macOS.
fn linkSystem(m: *std.Build.Module) void {
    for ([_][]const u8{ "Carbon", "ImageIO", "Quartz" }) |framework| m.linkFramework(framework, .{});
    m.linkSystemLibrary("sqlite3", .{});
}
