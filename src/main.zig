const std = @import("std");
const zz = @import("zigzag");
const meta_mod = @import("meta");
const app = @import("app");

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--help")) {
        printUsage();
        return;
    }

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--version")) {
        const file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        var buf: [256]u8 = undefined;
        var w = file.writer(&buf);
        try w.interface.print("sshz {s}\n", .{version});
        try w.interface.flush();
        return;
    }

    // sshz <host> [command...] — direct connect
    if (args.len >= 2 and args[1][0] != '-') {
        try directConnect(allocator, args[1], args[2..]);
        return;
    }

    // sshz — launch TUI
    try launchTui(allocator);
}

fn printUsage() void {
    const file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    w.interface.print(
        \\SSHZ - SSH Connection Manager
        \\
        \\Usage:
        \\  sshz                Launch TUI
        \\  sshz <host>         Connect to host
        \\  sshz <host> <cmd>   Run command on host
        \\  sshz --help         Show this help
        \\  sshz --version      Show version
        \\
    , .{}) catch {};
    w.interface.flush() catch {};
}

fn launchTui(allocator: std.mem.Allocator) !void {
    var program = try zz.Program(app.Model).init(allocator);
    try program.run();

    // Grab connect_host before deinit frees it
    var connect_buf: [256]u8 = undefined;
    var connect_host: ?[]const u8 = null;
    if (program.model.connect_host) |host_name| {
        if (host_name.len <= connect_buf.len) {
            @memcpy(connect_buf[0..host_name.len], host_name);
            connect_host = connect_buf[0..host_name.len];
        }
    }

    // Deinit BEFORE launching ssh — this restores terminal from raw mode
    program.deinit();

    if (connect_host) |host_name| {
        try directConnect(allocator, host_name, &.{});
    }
}

fn directConnect(allocator: std.mem.Allocator, host_name: []const u8, extra_args: []const [:0]u8) !void {
    // Record connection in meta.json
    const meta_path = try meta_mod.defaultMetaPath(allocator);
    defer allocator.free(meta_path);

    var store = try meta_mod.readFile(allocator, meta_path);
    defer store.deinit(allocator);

    try store.recordConnection(allocator, host_name);
    meta_mod.writeFile(allocator, &store, meta_path) catch {};

    // Build args
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);

    try argv.append(allocator, "ssh");
    try argv.append(allocator, host_name);
    for (extra_args) |arg| try argv.append(allocator, arg);

    // Exec ssh
    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();

    switch (term) {
        .Exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }
}
