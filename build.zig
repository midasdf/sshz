const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });

    // Source modules (shared between exe and tests)
    const ssh_config_mod = b.createModule(.{
        .root_source_file = b.path("src/ssh_config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const meta_mod = b.createModule(.{
        .root_source_file = b.path("src/meta.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
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
    exe_mod.addImport("ssh_config", ssh_config_mod);
    exe_mod.addImport("meta", meta_mod);
    exe_mod.addImport("utils", utils_mod);

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
    const test_step = b.step("test", "Run unit tests");

    const test_configs = [_]struct { name: []const u8, imports: []const struct { n: []const u8, m: *std.Build.Module } }{
        .{ .name = "test_ssh_config", .imports = &.{.{ .n = "ssh_config", .m = ssh_config_mod }} },
        .{ .name = "test_meta", .imports = &.{.{ .n = "meta", .m = meta_mod }} },
        .{ .name = "test_utils", .imports = &.{.{ .n = "utils", .m = utils_mod }} },
    };

    for (test_configs) |tc| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}.zig", .{tc.name})),
            .target = target,
            .optimize = optimize,
        });
        for (tc.imports) |imp| {
            test_mod.addImport(imp.n, imp.m);
        }

        const t = b.addTest(.{
            .name = tc.name,
            .root_module = test_mod,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
