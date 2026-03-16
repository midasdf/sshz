const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });
    const zigzag_mod = zigzag_dep.module("zigzag");

    // Source modules
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

    const checker_mod = b.createModule(.{
        .root_source_file = b.path("src/checker.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_mod.addImport("zigzag", zigzag_mod);
    app_mod.addImport("ssh_config", ssh_config_mod);
    app_mod.addImport("meta", meta_mod);
    app_mod.addImport("utils", utils_mod);
    app_mod.addImport("checker", checker_mod);

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize != .Debug) true else null,
    });
    exe_mod.addImport("zigzag", zigzag_mod);
    exe_mod.addImport("ssh_config", ssh_config_mod);
    exe_mod.addImport("meta", meta_mod);
    exe_mod.addImport("utils", utils_mod);
    exe_mod.addImport("checker", checker_mod);
    exe_mod.addImport("app", app_mod);

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

    const test_configs = [_]struct { name: []const u8, mod: *std.Build.Module }{
        .{ .name = "test_ssh_config", .mod = ssh_config_mod },
        .{ .name = "test_meta", .mod = meta_mod },
        .{ .name = "test_utils", .mod = utils_mod },
    };

    for (test_configs) |tc| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}.zig", .{tc.name})),
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport(std.fs.path.stem(tc.name)[5..], tc.mod); // "test_ssh_config" -> "ssh_config"

        const t = b.addTest(.{
            .name = tc.name,
            .root_module = test_mod,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
