const std = @import("std");
const zz = @import("zigzag");
const meta_mod = @import("meta");
const app = @import("app");

const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena_allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena_allocator);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--help")) {
        printUsage(init.io);
        return;
    }

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--version")) {
        const file = std.Io.File.stdout();
        var buf: [256]u8 = undefined;
        var w = file.writer(init.io, &buf);
        try w.interface.print("sshz {s}\n", .{version});
        try w.interface.flush();
        return;
    }

    // sshz <host> [command...] — direct connect
    if (args.len >= 2 and args[1][0] != '-') {
        try directConnect(allocator, init.io, init.environ_map, args[1], args[2..]);
        return;
    }

    // sshz — launch TUI
    try launchTui(init);
}

fn printUsage(io: std.Io) void {
    const file = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
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

fn launchTui(init: std.process.Init) !void {
    const allocator = init.gpa;
    var program = try zz.Program(app.Model).init(init.gpa, init.io, init.environ_map);
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
        try directConnect(allocator, init.io, init.environ_map, host_name, &.{});
    }
}

fn directConnect(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, host_name: []const u8, extra_args: []const [:0]const u8) !void {
    // Record connection in meta.json
    const meta_path = try meta_mod.defaultMetaPath(allocator, env);
    defer allocator.free(meta_path);

    var store = try meta_mod.readFile(allocator, io, meta_path);
    defer store.deinit(allocator);

    try store.recordConnection(allocator, host_name);
    meta_mod.writeFile(allocator, io, &store, meta_path) catch {};

    // Build args
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "ssh");
    try argv.append(allocator, host_name);
    for (extra_args) |arg| try argv.append(allocator, arg);

    // Exec ssh
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);

    switch (term) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }
}
