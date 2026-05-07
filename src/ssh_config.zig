const std = @import("std");

pub const AddressFamily = enum {
    any,
    inet,
    inet6,

    pub fn toString(self: AddressFamily) []const u8 {
        return switch (self) {
            .any => "any",
            .inet => "inet",
            .inet6 => "inet6",
        };
    }

    pub fn fromString(s: []const u8) ?AddressFamily {
        if (std.ascii.eqlIgnoreCase(s, "any")) return .any;
        if (std.ascii.eqlIgnoreCase(s, "inet")) return .inet;
        if (std.ascii.eqlIgnoreCase(s, "inet6")) return .inet6;
        return null;
    }
};

pub const Host = struct {
    name: []const u8,
    hostname: ?[]const u8 = null,
    user: ?[]const u8 = null,
    port: ?u16 = null,
    identity_file: ?[]const u8 = null,
    proxy_jump: ?[]const u8 = null,
    proxy_command: ?[]const u8 = null,
    local_forward: ?[]const u8 = null,
    remote_forward: ?[]const u8 = null,
    dynamic_forward: ?[]const u8 = null,
    address_family: ?AddressFamily = null,
    start_line: usize = 0,
    end_line: usize = 0,
    is_wildcard: bool = false,
};

pub const Config = struct {
    /// Each Host's string fields (`name`, `hostname`, `user`, ...) are
    /// owned by `allocator`. `parse`/`addHost` allocate copies; `removeHost`
    /// and `deinit` free them via `freeHostStrings`.
    hosts: []Host,
    /// Each `raw_lines` element is owned by `allocator`.
    raw_lines: [][]const u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.hosts) |h| freeHostStrings(allocator, h);
        allocator.free(self.hosts);
        for (self.raw_lines) |line| allocator.free(line);
        allocator.free(self.raw_lines);
    }

    pub fn effectiveHostname(host: Host) []const u8 {
        return host.hostname orelse host.name;
    }

    pub fn effectivePort(host: Host) u16 {
        return host.port orelse 22;
    }

    pub fn effectiveUser(host: Host, default_user: []const u8) []const u8 {
        return host.user orelse default_user;
    }

    pub fn findHost(self: *const Config, name: []const u8) ?*const Host {
        for (self.hosts) |*h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h;
        }
        return null;
    }
};

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
    }
    return true;
}

fn freeHostStrings(allocator: std.mem.Allocator, host: Host) void {
    allocator.free(host.name);
    if (host.hostname) |v| allocator.free(v);
    if (host.user) |v| allocator.free(v);
    if (host.identity_file) |v| allocator.free(v);
    if (host.proxy_jump) |v| allocator.free(v);
    if (host.proxy_command) |v| allocator.free(v);
    if (host.local_forward) |v| allocator.free(v);
    if (host.remote_forward) |v| allocator.free(v);
    if (host.dynamic_forward) |v| allocator.free(v);
}

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Config {
    var hosts: std.ArrayList(Host) = .empty;
    errdefer {
        for (hosts.items) |h| freeHostStrings(allocator, h);
        hosts.deinit(allocator);
    }

    var lines_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines_list.items) |line| allocator.free(line);
        lines_list.deinit(allocator);
    }

    var current_host: ?Host = null;
    errdefer if (current_host) |h| freeHostStrings(allocator, h);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;
    var in_match_block: bool = false;

    while (line_iter.next()) |line| {
        const owned_line = try allocator.dupe(u8, line);
        {
            errdefer allocator.free(owned_line);
            try lines_list.append(allocator, owned_line);
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0 or trimmed[0] == '#') {
            line_num += 1;
            continue;
        }

        // Skip Include directives (resolved separately)
        if (startsWithIgnoreCase(trimmed, "Include ") or
            startsWithIgnoreCase(trimmed, "Include\t"))
        {
            line_num += 1;
            continue;
        }

        // Handle Match blocks
        if (startsWithIgnoreCase(trimmed, "Match ") or
            startsWithIgnoreCase(trimmed, "Match\t"))
        {
            if (current_host) |h| {
                var hh = h;
                hh.end_line = line_num;
                try hosts.append(allocator, hh);
                current_host = null;
            }
            in_match_block = true;
            line_num += 1;
            continue;
        }

        const kv = parseKeyValue(trimmed) orelse {
            line_num += 1;
            continue;
        };

        if (std.ascii.eqlIgnoreCase(kv.key, "Host")) {
            in_match_block = false;
            if (current_host) |h| {
                var hh = h;
                hh.end_line = line_num;
                try hosts.append(allocator, hh);
                current_host = null;
            }
            const is_wildcard = std.mem.indexOfScalar(u8, kv.value, '*') != null or
                std.mem.indexOfScalar(u8, kv.value, '?') != null;
            const name_dup = try allocator.dupe(u8, kv.value);
            current_host = Host{
                .name = name_dup,
                .start_line = line_num,
                .is_wildcard = is_wildcard,
            };
        } else if (!in_match_block) {
            if (current_host) |*h| {
                try setHostField(allocator, h, kv.key, kv.value);
            }
        }

        line_num += 1;
    }

    if (current_host) |h| {
        var hh = h;
        hh.end_line = line_num;
        try hosts.append(allocator, hh);
        current_host = null;
    }

    return Config{
        .hosts = try hosts.toOwnedSlice(allocator),
        .raw_lines = try lines_list.toOwnedSlice(allocator),
    };
}

const KeyValue = struct { key: []const u8, value: []const u8 };

fn parseKeyValue(line: []const u8) ?KeyValue {
    var i: usize = 0;
    while (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '=') : (i += 1) {}
    if (i == 0 or i >= line.len) return null;

    const key = line[0..i];

    while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '=')) : (i += 1) {}
    if (i >= line.len) return null;

    const value = std.mem.trim(u8, line[i..], " \t\r");
    return KeyValue{ .key = key, .value = value };
}

fn setHostField(allocator: std.mem.Allocator, h: *Host, key: []const u8, value: []const u8) !void {
    // Pattern: dupe first, then free old (so a failed dup doesn't dangle the
    // old value). Repeated keys in the same Host block are rare but legal.
    if (std.ascii.eqlIgnoreCase(key, "HostName")) {
        const new_val = try allocator.dupe(u8, value);
        if (h.hostname) |old| allocator.free(old);
        h.hostname = new_val;
    } else if (std.ascii.eqlIgnoreCase(key, "User")) {
        const new_val = try allocator.dupe(u8, value);
        if (h.user) |old| allocator.free(old);
        h.user = new_val;
    } else if (std.ascii.eqlIgnoreCase(key, "Port")) {
        h.port = std.fmt.parseInt(u16, value, 10) catch null;
    } else if (std.ascii.eqlIgnoreCase(key, "IdentityFile")) {
        const new_val = try allocator.dupe(u8, value);
        if (h.identity_file) |old| allocator.free(old);
        h.identity_file = new_val;
    } else if (std.ascii.eqlIgnoreCase(key, "ProxyJump")) {
        const new_val = try allocator.dupe(u8, value);
        if (h.proxy_jump) |old| allocator.free(old);
        h.proxy_jump = new_val;
    } else if (std.ascii.eqlIgnoreCase(key, "ProxyCommand")) {
        const new_val = try allocator.dupe(u8, value);
        if (h.proxy_command) |old| allocator.free(old);
        h.proxy_command = new_val;
    } else if (std.ascii.eqlIgnoreCase(key, "LocalForward")) {
        const new_val = try allocator.dupe(u8, value);
        if (h.local_forward) |old| allocator.free(old);
        h.local_forward = new_val;
    } else if (std.ascii.eqlIgnoreCase(key, "RemoteForward")) {
        const new_val = try allocator.dupe(u8, value);
        if (h.remote_forward) |old| allocator.free(old);
        h.remote_forward = new_val;
    } else if (std.ascii.eqlIgnoreCase(key, "DynamicForward")) {
        const new_val = try allocator.dupe(u8, value);
        if (h.dynamic_forward) |old| allocator.free(old);
        h.dynamic_forward = new_val;
    } else if (std.ascii.eqlIgnoreCase(key, "AddressFamily")) {
        h.address_family = AddressFamily.fromString(value);
    }
}

pub fn serialize(allocator: std.mem.Allocator, config: *const Config) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (config.raw_lines) |line| {
        try result.appendSlice(allocator, line);
        try result.append(allocator, '\n');
    }

    return try result.toOwnedSlice(allocator);
}

/// Append `host` to `config`. `addHost` takes ownership: it deep-copies
/// every string field of `host` and every line in `config.raw_lines`, so
/// callers may pass borrowed slices (form input, string literals) safely.
pub fn addHost(allocator: std.mem.Allocator, config: *Config, host: Host) !void {
    // Phase 1: build all new owned state in locals. On any failure, the
    // errdefers free everything we allocated; `config` stays untouched.

    var new_lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (new_lines.items) |s| allocator.free(s);
        new_lines.deinit(allocator);
    }

    for (config.raw_lines) |l| {
        try new_lines.append(allocator, try allocator.dupe(u8, l));
    }
    try new_lines.append(allocator, try allocator.dupe(u8, ""));

    const host_start_line = new_lines.items.len;
    try new_lines.append(allocator, try std.fmt.allocPrint(allocator, "Host {s}", .{host.name}));
    if (host.hostname) |v| {
        try new_lines.append(allocator, try std.fmt.allocPrint(allocator, "    HostName {s}", .{v}));
    }
    if (host.user) |v| {
        try new_lines.append(allocator, try std.fmt.allocPrint(allocator, "    User {s}", .{v}));
    }
    if (host.port) |p| {
        try new_lines.append(allocator, try std.fmt.allocPrint(allocator, "    Port {d}", .{p}));
    }
    if (host.identity_file) |v| {
        try new_lines.append(allocator, try std.fmt.allocPrint(allocator, "    IdentityFile {s}", .{v}));
    }
    if (host.proxy_jump) |v| {
        try new_lines.append(allocator, try std.fmt.allocPrint(allocator, "    ProxyJump {s}", .{v}));
    }
    if (host.address_family) |af| {
        try new_lines.append(allocator, try std.fmt.allocPrint(allocator, "    AddressFamily {s}", .{af.toString()}));
    }
    const host_end_line = new_lines.items.len;

    var new_host: Host = .{
        .name = try allocator.dupe(u8, host.name),
        .start_line = host_start_line,
        .end_line = host_end_line,
        .is_wildcard = host.is_wildcard,
        .port = host.port,
        .address_family = host.address_family,
    };
    errdefer freeHostStrings(allocator, new_host);

    if (host.hostname) |v| new_host.hostname = try allocator.dupe(u8, v);
    if (host.user) |v| new_host.user = try allocator.dupe(u8, v);
    if (host.identity_file) |v| new_host.identity_file = try allocator.dupe(u8, v);
    if (host.proxy_jump) |v| new_host.proxy_jump = try allocator.dupe(u8, v);
    if (host.proxy_command) |v| new_host.proxy_command = try allocator.dupe(u8, v);
    if (host.local_forward) |v| new_host.local_forward = try allocator.dupe(u8, v);
    if (host.remote_forward) |v| new_host.remote_forward = try allocator.dupe(u8, v);
    if (host.dynamic_forward) |v| new_host.dynamic_forward = try allocator.dupe(u8, v);

    var new_hosts: std.ArrayList(Host) = .empty;
    errdefer new_hosts.deinit(allocator);
    for (config.hosts) |h| try new_hosts.append(allocator, h);
    try new_hosts.append(allocator, new_host);

    // Phase 2: commit. Past `toOwnedSlice` only no-fail operations remain.
    const new_lines_slice = try new_lines.toOwnedSlice(allocator);
    const new_hosts_slice = new_hosts.toOwnedSlice(allocator) catch |err| {
        // Couldn't commit hosts — release the lines we just took ownership of
        // (they reference the allocator-owned strings we duped above).
        for (new_lines_slice) |s| allocator.free(s);
        allocator.free(new_lines_slice);
        return err;
    };

    // Free old raw_lines content (each element was allocator-owned) and array.
    for (config.raw_lines) |l| allocator.free(l);
    allocator.free(config.raw_lines);
    config.raw_lines = new_lines_slice;

    // Old `config.hosts` array is replaced; the host structs inside still
    // reference their own owned strings, which transfer through `new_hosts`.
    allocator.free(config.hosts);
    config.hosts = new_hosts_slice;
}

pub fn removeHost(allocator: std.mem.Allocator, config: *Config, index: usize) !void {
    if (index >= config.hosts.len) return;

    const host = config.hosts[index];
    const start = host.start_line;
    const end = @min(host.end_line, config.raw_lines.len);
    const removed_count = end - start;

    // Phase 1: build new arrays without committing.
    var new_lines: std.ArrayList([]const u8) = .empty;
    errdefer new_lines.deinit(allocator);
    for (config.raw_lines, 0..) |line, i| {
        if (i >= start and i < end) continue;
        try new_lines.append(allocator, line);
    }

    var new_hosts: std.ArrayList(Host) = .empty;
    errdefer new_hosts.deinit(allocator);
    for (config.hosts, 0..) |h, i| {
        if (i == index) continue;
        var adjusted = h;
        if (h.start_line >= end) {
            adjusted.start_line -= removed_count;
            adjusted.end_line -= removed_count;
        }
        try new_hosts.append(allocator, adjusted);
    }

    // Phase 2: commit. Take ownership of the new slices, then free the
    // strings that are no longer referenced.
    const new_lines_slice = try new_lines.toOwnedSlice(allocator);
    const new_hosts_slice = new_hosts.toOwnedSlice(allocator) catch |err| {
        allocator.free(new_lines_slice);
        return err;
    };

    // Free strings of the lines being dropped, then the old array.
    for (config.raw_lines[start..end]) |line| allocator.free(line);
    allocator.free(config.raw_lines);
    config.raw_lines = new_lines_slice;

    // Free the removed host's owned string fields, then the old array.
    freeHostStrings(allocator, host);
    allocator.free(config.hosts);
    config.hosts = new_hosts_slice;
}

pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const cwd = std.Io.Dir.cwd();
    const content = try cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(content);
    // `parse` deep-copies all strings out of `content`, so it's safe to free
    // the buffer here.
    return parse(allocator, content);
}

pub fn writeFile(allocator: std.mem.Allocator, io: std.Io, config: *const Config, path: []const u8, backup_dir: []const u8) !void {
    backupFile(allocator, io, path, backup_dir) catch {};

    const content = try serialize(allocator, config);
    defer allocator.free(content);

    const dir_path = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);

    var tmp_name_buf: [256]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_name_buf, ".{s}.tmp", .{basename}) catch return error.NameTooLong;

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    var dir_fd = try cwd.openDir(io, dir_path, .{});
    defer dir_fd.close(io);

    {
        const tmp_file = try dir_fd.createFile(io, tmp_name, .{});
        defer tmp_file.close(io);
        var write_buf: [4096]u8 = undefined;
        var w = tmp_file.writer(io, &write_buf);
        try w.interface.writeAll(content);
        try w.interface.flush();
    }

    try dir_fd.rename(tmp_name, dir_fd, basename, io);
}

fn backupFile(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, backup_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, backup_dir);

    const content = cwd.readFileAlloc(io, source_path, allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(content);

    const ts = std.Io.Timestamp.now(io, .real).toSeconds();
    var name_buf: [256]u8 = undefined;
    const backup_name = std.fmt.bufPrint(&name_buf, "ssh_config_{d}", .{ts}) catch return;

    var path_buf: [512]u8 = undefined;
    const backup_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ backup_dir, backup_name }) catch return;

    {
        const dest = try cwd.createFile(io, backup_path, .{});
        defer dest.close(io);
        var write_buf: [4096]u8 = undefined;
        var w = dest.writer(io, &write_buf);
        try w.interface.writeAll(content);
        try w.interface.flush();
    }

    rotateBackups(allocator, io, backup_dir) catch {};
}

fn rotateBackups(allocator: std.mem.Allocator, io: std.Io, backup_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, backup_dir, .{ .iterate = true });
    defer dir.close(io);

    var entries: std.ArrayList([]const u8) = .empty;
    defer {
        for (entries.items) |name| allocator.free(@constCast(name));
        entries.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "ssh_config_")) {
            try entries.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    if (entries.items.len <= 10) return;

    std.mem.sort([]const u8, entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    const to_delete = entries.items.len - 10;
    for (entries.items[0..to_delete]) |name| {
        try dir.deleteFile(io, name);
    }
}

pub fn defaultConfigPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.ssh/config", .{home});
}
