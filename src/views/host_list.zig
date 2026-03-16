const std = @import("std");
const zz = @import("zigzag");
const ssh_config = @import("ssh_config");
const utils = @import("utils");
const App = @import("../app.zig");

pub fn render(model: *const App.Model, ctx: *const zz.Context) ![]const u8 {
    const a = ctx.allocator;
    const w = ctx.width;

    // Title
    const title_style = (zz.Style{}).bold(true).fg(zz.Color.cyan());
    const title = try title_style.render(a, " SSHZ - SSH Manager");

    // Host count
    const host_count = model.hosts.items.len;
    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d} hosts ", .{host_count}) catch "? hosts";
    const dim = (zz.Style{}).fg(zz.Color.gray(12));
    const count_rendered = try dim.render(a, count_str);

    const title_w: u16 = @intCast(@min(zz.width(title), w));
    const count_w: u16 = @intCast(@min(zz.width(count_rendered), w));
    const spacer_w = w -| title_w -| count_w;
    const header = try zz.joinHorizontal(a, &.{
        title,
        try (zz.Style{}).width(spacer_w).render(a, ""),
        count_rendered,
    });

    // Separator
    const sep_chars = try a.alloc(u8, @min(w, 120));
    @memset(sep_chars, '-');
    const separator = try dim.render(a, sep_chars);

    // Build lines
    var lines: std.ArrayList([]const u8) = .{};
    defer lines.deinit(a);
    try lines.append(a, header);
    try lines.append(a, separator);

    // Filtered host list
    var display_idx: usize = 0;
    for (model.hosts.items) |entry| {
        // Search filter
        if (model.search_text.items.len > 0) {
            if (!matchesSearch(entry, model.search_text.items)) continue;
        }

        // Tag filter
        if (model.tag_filter) |tag| {
            if (!hasTag(entry, tag)) continue;
        }

        const is_selected = (display_idx == model.selected);
        const line = try renderHostLine(a, entry, is_selected, w);
        try lines.append(a, line);
        display_idx += 1;
    }

    if (display_idx == 0) {
        const empty_style = (zz.Style{}).fg(zz.Color.gray(10)).italic(true);
        try lines.append(a, try empty_style.render(a, "  No hosts found. Press 'a' to add one."));
    }

    try lines.append(a, separator);

    // Bottom bar
    if (model.search_active) {
        const search_style = (zz.Style{}).fg(zz.Color.fromRgb(255, 200, 0));
        const prompt = try std.fmt.allocPrint(a, " /{s}_", .{model.search_text.items});
        try lines.append(a, try search_style.render(a, prompt));
    } else if (model.confirm_delete) {
        if (model.selected < model.hosts.items.len) {
            const warn_style = (zz.Style{}).fg(zz.Color.fromRgb(255, 80, 80)).bold(true);
            const name = model.hosts.items[model.selected].config.name;
            const msg = try std.fmt.allocPrint(a, " Delete '{s}'? (y/n)", .{name});
            try lines.append(a, try warn_style.render(a, msg));
        }
    } else {
        const sort_name = switch (model.sort_mode) {
            .name => "name",
            .recent => "recent",
            .tag => "tag",
        };
        const filter_info = if (model.tag_filter) |tag|
            try std.fmt.allocPrint(a, " [tag:{s}]", .{tag})
        else
            "";
        const help = try std.fmt.allocPrint(a, " j/k nav  Enter connect  a add  e edit  d del  / search  s sort:{s}  t tag{s}  ? help  q quit", .{ sort_name, filter_info });
        try lines.append(a, try dim.render(a, help));
    }

    // Notification
    if (model.notification) |note| {
        const note_style = (zz.Style{}).fg(zz.Color.fromRgb(100, 255, 100)).bold(true);
        try lines.append(a, try note_style.render(a, note));
    }

    return try zz.joinVertical(a, lines.items);
}

fn matchesSearch(entry: App.HostEntry, search: []const u8) bool {
    if (std.mem.indexOf(u8, entry.config.name, search) != null) return true;
    if (entry.config.hostname) |hn| {
        if (std.mem.indexOf(u8, hn, search) != null) return true;
    }
    if (entry.config.user) |u| {
        if (std.mem.indexOf(u8, u, search) != null) return true;
    }
    if (entry.meta) |m| {
        for (m.tags) |tag| {
            if (std.mem.indexOf(u8, tag, search) != null) return true;
        }
    }
    return false;
}

fn hasTag(entry: App.HostEntry, tag: []const u8) bool {
    if (entry.meta) |m| {
        for (m.tags) |t| {
            if (std.mem.eql(u8, t, tag)) return true;
        }
    }
    return false;
}

fn renderHostLine(a: std.mem.Allocator, entry: App.HostEntry, is_selected: bool, width: u16) ![]const u8 {
    // Status indicator
    const StatusInfo = struct { sym: []const u8, color: zz.Color };
    const status_info: StatusInfo = switch (entry.status) {
        .online => .{ .sym = "●", .color = zz.Color.fromRgb(0, 255, 0) },
        .offline => .{ .sym = "○", .color = zz.Color.fromRgb(255, 60, 60) },
        .checking => .{ .sym = "◌", .color = zz.Color.fromRgb(255, 200, 0) },
        .unknown => .{ .sym = "?", .color = zz.Color.gray(12) },
    };
    const status = try (zz.Style{}).fg(status_info.color).render(a, status_info.sym);

    // Host name (max 18 chars)
    var name_buf: [20]u8 = undefined;
    const display_name = utils.truncate(entry.config.name, 18, &name_buf);
    var padded_name: [20]u8 = undefined;
    const name_padded = std.fmt.bufPrint(&padded_name, "{s:<18}", .{display_name}) catch display_name;

    // Connection info
    const hostname = ssh_config.Config.effectiveHostname(entry.config);
    const port = ssh_config.Config.effectivePort(entry.config);
    const user = entry.config.user orelse "?";
    const conn_info = try std.fmt.allocPrint(a, "{s}@{s}:{d}", .{ user, hostname, port });
    var conn_buf: [30]u8 = undefined;
    const display_conn = utils.truncate(conn_info, 28, &conn_buf);

    // Tags
    var tags_str: []const u8 = "";
    if (entry.meta) |m| {
        if (m.tags.len > 0) {
            var tag_buf: std.ArrayList(u8) = .{};
            defer tag_buf.deinit(a);
            try tag_buf.appendSlice(a, "[");
            for (m.tags, 0..) |tag, j| {
                if (j > 0) try tag_buf.appendSlice(a, ",");
                try tag_buf.appendSlice(a, tag);
            }
            try tag_buf.appendSlice(a, "]");
            tags_str = try tag_buf.toOwnedSlice(a);
        }
    }

    // Last connected
    var time_buf: [32]u8 = undefined;
    const last_time = if (entry.meta) |m|
        utils.relativeTimeFromTimestamp(m.last_connected, &time_buf)
    else
        "never";

    // Compose
    const line = try std.fmt.allocPrint(a, " {s} {s}  {s:<28}  {s:<14}  {s}", .{
        status, name_padded, display_conn, tags_str, last_time,
    });

    if (is_selected) {
        return try (zz.Style{}).bg(zz.Color.gray(4)).bold(true).width(width).render(a, line);
    }
    return line;
}
