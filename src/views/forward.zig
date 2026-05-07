const std = @import("std");
const zz = @import("zigzag");
const meta_mod = @import("meta");

pub const ForwardEntry = struct {
    forward: meta_mod.PortForward,
    enabled: bool = true,
};

pub const ForwardState = struct {
    host_name: []const u8,
    entries: std.ArrayList(ForwardEntry),
    selected: usize = 0,

    pub fn init(allocator: std.mem.Allocator, host_name: []const u8, forwards: []const meta_mod.PortForward) ForwardState {
        var entries: std.ArrayList(ForwardEntry) = .empty;
        for (forwards) |fwd| {
            entries.append(allocator, .{ .forward = fwd }) catch {};
        }
        return .{ .host_name = host_name, .entries = entries };
    }

    pub fn deinit(self: *ForwardState, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn toggle(self: *ForwardState) void {
        if (self.selected < self.entries.items.len) {
            self.entries.items[self.selected].enabled = !self.entries.items[self.selected].enabled;
        }
    }

    pub fn moveUp(self: *ForwardState) void {
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *ForwardState) void {
        if (self.selected + 1 < self.entries.items.len) self.selected += 1;
    }
};

pub fn render(state: *const ForwardState, ctx: *const zz.Context) ![]const u8 {
    const a = ctx.allocator;

    const title_style = (zz.Style{}).bold(true).fg(zz.Color.cyan);
    const title = try std.fmt.allocPrint(a, " Connect to {s}", .{state.host_name});
    const title_rendered = try title_style.render(a, title);

    const dim = (zz.Style{}).fg(zz.Color.gray(12));
    const sep_chars = try a.alloc(u8, @min(ctx.width, 60));
    @memset(sep_chars, '-');
    const sep = try dim.render(a, sep_chars);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    try lines.append(a, title_rendered);
    try lines.append(a, sep);

    if (state.entries.items.len == 0) {
        try lines.append(a, try dim.render(a, "  No saved port forwards."));
        try lines.append(a, try dim.render(a, "  Press Enter to connect directly."));
    } else {
        try lines.append(a, try dim.render(a, " Saved forwards:"));
        for (state.entries.items, 0..) |entry, i| {
            const is_sel = (i == state.selected);
            const checkbox = if (entry.enabled) "[x]" else "[ ]";
            const type_char: []const u8 = switch (entry.forward.forward_type[0]) {
                'l' => "L",
                'r' => "R",
                'd' => "D",
                else => "?",
            };
            const line = if (entry.forward.target.len > 0)
                try std.fmt.allocPrint(a, "   {s} {s} {s} -> {s}", .{ checkbox, type_char, entry.forward.bind, entry.forward.target })
            else
                try std.fmt.allocPrint(a, "   {s} {s} {s}", .{ checkbox, type_char, entry.forward.bind });

            if (is_sel) {
                try lines.append(a, try (zz.Style{}).bg(zz.Color.gray(4)).bold(true).render(a, line));
            } else {
                try lines.append(a, line);
            }
        }
    }

    try lines.append(a, sep);
    try lines.append(a, try dim.render(a, " Space: toggle  Enter: connect  Esc: cancel"));

    return try zz.joinVertical(a, lines.items);
}
