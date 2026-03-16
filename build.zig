const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize != .Debug) true else null,
    });
    exe_mod.addImport("zigzag", zigzag_dep.module("zigzag"));

    const exe = b.addExecutable(.{
        .name = "sshz",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run SSHZ");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_names = [_][]const u8{ "test_ssh_config", "test_meta", "test_utils" };
    const test_step = b.step("test", "Run unit tests");

    for (test_names) |name| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        // Allow test files to import src modules
        test_mod.addImport("zigzag", zigzag_dep.module("zigzag"));

        const t = b.addTest(.{
            .name = name,
            .root_module = test_mod,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
