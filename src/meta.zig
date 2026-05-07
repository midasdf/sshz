const std = @import("std");

pub const PortForward = struct {
    forward_type: []const u8, // "local", "remote", "dynamic"
    bind: []const u8,
    target: []const u8,
};

pub const HostMeta = struct {
    tags: []const []const u8 = &.{},
    last_connected: i64 = 0,
    connect_count: u32 = 0,
    port_forwards: []const PortForward = &.{},
};

pub const MetaStore = struct {
    version: u32 = 1,
    entries: std.StringHashMap(HostMeta),

    pub fn empty() MetaStore {
        return .{ .entries = std.StringHashMap(HostMeta).init(std.heap.page_allocator) };
    }

    pub fn initWith(allocator: std.mem.Allocator) MetaStore {
        return .{ .entries = std.StringHashMap(HostMeta).init(allocator) };
    }

    pub fn deinit(self: *MetaStore, allocator: std.mem.Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.tags) |tag| allocator.free(tag);
            if (entry.value_ptr.tags.len > 0) allocator.free(entry.value_ptr.tags);
            for (entry.value_ptr.port_forwards) |fwd| {
                allocator.free(fwd.forward_type);
                allocator.free(fwd.bind);
                allocator.free(fwd.target);
            }
            if (entry.value_ptr.port_forwards.len > 0) allocator.free(entry.value_ptr.port_forwards);
            allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn getHost(self: *const MetaStore, name: []const u8) ?*const HostMeta {
        return self.entries.getPtr(name);
    }

    pub fn recordConnection(self: *MetaStore, allocator: std.mem.Allocator, name: []const u8) !void {
        const now = std.time.timestamp();
        if (self.entries.getPtr(name)) |entry| {
            entry.last_connected = now;
            entry.connect_count += 1;
        } else {
            const duped_name = try allocator.dupe(u8, name);
            try self.entries.put(duped_name, HostMeta{
                .last_connected = now,
                .connect_count = 1,
            });
        }
    }

    pub fn setTags(self: *MetaStore, allocator: std.mem.Allocator, name: []const u8, tags: []const []const u8) !void {
        const duped_tags = try allocator.alloc([]const u8, tags.len);
        for (tags, 0..) |tag, i| {
            duped_tags[i] = try allocator.dupe(u8, tag);
        }

        if (self.entries.getPtr(name)) |entry| {
            for (entry.tags) |tag| allocator.free(tag);
            if (entry.tags.len > 0) allocator.free(entry.tags);
            entry.tags = duped_tags;
        } else {
            const duped_name = try allocator.dupe(u8, name);
            try self.entries.put(duped_name, HostMeta{
                .tags = duped_tags,
            });
        }
    }

    pub fn setPortForwards(self: *MetaStore, allocator: std.mem.Allocator, name: []const u8, forwards: []const PortForward) !void {
        const duped = try allocator.alloc(PortForward, forwards.len);
        for (forwards, 0..) |fwd, i| {
            duped[i] = .{
                .forward_type = try allocator.dupe(u8, fwd.forward_type),
                .bind = try allocator.dupe(u8, fwd.bind),
                .target = try allocator.dupe(u8, fwd.target),
            };
        }

        if (self.entries.getPtr(name)) |entry| {
            for (entry.port_forwards) |fwd| {
                allocator.free(fwd.forward_type);
                allocator.free(fwd.bind);
                allocator.free(fwd.target);
            }
            if (entry.port_forwards.len > 0) allocator.free(entry.port_forwards);
            entry.port_forwards = duped;
        } else {
            const duped_name = try allocator.dupe(u8, name);
            try self.entries.put(duped_name, HostMeta{
                .port_forwards = duped,
            });
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !MetaStore {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    var store = MetaStore.initWith(allocator);

    const root = parsed.value.object;
    if (root.get("version")) |v| {
        store.version = @intCast(v.integer);
    }

    if (root.get("hosts")) |hosts_val| {
        var hosts_it = hosts_val.object.iterator();
        while (hosts_it.next()) |entry| {
            const name = try allocator.dupe(u8, entry.key_ptr.*);
            const obj = entry.value_ptr.object;

            var tags_list: std.ArrayList([]const u8) = .empty;
            defer tags_list.deinit(allocator);
            if (obj.get("tags")) |tags_val| {
                for (tags_val.array.items) |tag| {
                    try tags_list.append(allocator, try allocator.dupe(u8, tag.string));
                }
            }

            var fwds_list: std.ArrayList(PortForward) = .empty;
            defer fwds_list.deinit(allocator);
            if (obj.get("port_forwards")) |fwds_val| {
                for (fwds_val.array.items) |fwd| {
                    const fwd_obj = fwd.object;
                    try fwds_list.append(allocator, .{
                        .forward_type = try allocator.dupe(u8, if (fwd_obj.get("type")) |t| t.string else "local"),
                        .bind = try allocator.dupe(u8, if (fwd_obj.get("bind")) |b_val| b_val.string else ""),
                        .target = try allocator.dupe(u8, if (fwd_obj.get("target")) |t| t.string else ""),
                    });
                }
            }

            const last_connected: i64 = if (obj.get("last_connected")) |lc| lc.integer else 0;
            const connect_count: u32 = if (obj.get("connect_count")) |cc| @intCast(cc.integer) else 0;

            try store.entries.put(name, HostMeta{
                .tags = try tags_list.toOwnedSlice(allocator),
                .last_connected = last_connected,
                .connect_count = connect_count,
                .port_forwards = try fwds_list.toOwnedSlice(allocator),
            });
        }
    }

    return store;
}

pub fn serialize(allocator: std.mem.Allocator, store: *const MetaStore) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"version\": ");
    var num_buf: [32]u8 = undefined;
    var num_str = std.fmt.bufPrint(&num_buf, "{d}", .{store.version}) catch "1";
    try buf.appendSlice(allocator, num_str);
    try buf.appendSlice(allocator, ",\n  \"hosts\": {");

    var first = true;
    var it = store.entries.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, "\n    \"");
        try buf.appendSlice(allocator, entry.key_ptr.*);
        try buf.appendSlice(allocator, "\": {\n      \"tags\": [");

        for (entry.value_ptr.tags, 0..) |tag, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, "\"");
            try buf.appendSlice(allocator, tag);
            try buf.appendSlice(allocator, "\"");
        }

        try buf.appendSlice(allocator, "],\n      \"last_connected\": ");
        num_str = std.fmt.bufPrint(&num_buf, "{d}", .{entry.value_ptr.last_connected}) catch "0";
        try buf.appendSlice(allocator, num_str);
        try buf.appendSlice(allocator, ",\n      \"connect_count\": ");
        num_str = std.fmt.bufPrint(&num_buf, "{d}", .{entry.value_ptr.connect_count}) catch "0";
        try buf.appendSlice(allocator, num_str);
        try buf.appendSlice(allocator, ",\n      \"port_forwards\": [");

        for (entry.value_ptr.port_forwards, 0..) |fwd, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, "{\"type\": \"");
            try buf.appendSlice(allocator, fwd.forward_type);
            try buf.appendSlice(allocator, "\", \"bind\": \"");
            try buf.appendSlice(allocator, fwd.bind);
            try buf.appendSlice(allocator, "\", \"target\": \"");
            try buf.appendSlice(allocator, fwd.target);
            try buf.appendSlice(allocator, "\"}");
        }

        try buf.appendSlice(allocator, "]\n    }");
    }

    try buf.appendSlice(allocator, "\n  }\n}\n");
    return try buf.toOwnedSlice(allocator);
}

pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !MetaStore {
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return MetaStore.initWith(allocator),
        else => return err,
    };
    defer allocator.free(content);
    return parse(allocator, content) catch MetaStore.initWith(allocator);
}

pub fn writeFile(allocator: std.mem.Allocator, io: std.Io, store: *const MetaStore, path: []const u8) !void {
    const content = try serialize(allocator, store);
    defer allocator.free(content);

    const dir_path = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir_path) catch {};

    var tmp_buf: [256]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_buf, ".{s}.tmp", .{basename}) catch return error.NameTooLong;

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

pub fn defaultMetaPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/sshz/meta.json", .{home});
}

pub fn defaultBackupDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/sshz/backups", .{home});
}
