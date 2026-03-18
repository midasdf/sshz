const std = @import("std");
const zz = @import("zigzag");

pub fn render(ctx: *const zz.Context) ![]const u8 {
    const a = ctx.allocator;

    const title_style = (zz.Style{}).bold(true).fg(zz.Color.cyan());
    const key_style = (zz.Style{}).bold(true).fg(zz.Color.fromRgb(255, 200, 0));
    const dim = (zz.Style{}).fg(zz.Color.gray(15));

    const bindings = [_][2][]const u8{
        .{ "j/k, Up/Down  ", "Navigate hosts" },
        .{ "Enter          ", "Connect to host" },
        .{ "a              ", "Add new host" },
        .{ "e              ", "Edit selected host" },
        .{ "d              ", "Delete selected host" },
        .{ "/              ", "Search hosts" },
        .{ "t              ", "Cycle tag filter" },
        .{ "s              ", "Cycle sort mode" },
        .{ "r              ", "Refresh status" },
        .{ "f              ", "Port forward config" },
        .{ "?              ", "Toggle help" },
        .{ "q              ", "Quit" },
    };

    var lines: std.ArrayList([]const u8) = .{};
    defer lines.deinit(a);

    try lines.append(a, try title_style.render(a, " sshz Keybindings"));
    try lines.append(a, "");

    for (bindings) |b| {
        const key_part = try key_style.render(a, b[0]);
        const desc_part = try dim.render(a, b[1]);
        const row = try zz.joinHorizontal(a, &.{ "  ", key_part, desc_part });
        try lines.append(a, row);
    }

    try lines.append(a, "");
    try lines.append(a, try dim.render(a, "  Press Esc or ? to close"));

    const content = try zz.joinVertical(a, lines.items);

    return try (zz.Style{})
        .borderAll(zz.Border.rounded)
        .borderForeground(zz.Color.cyan())
        .paddingAll(1)
        .width(@min(ctx.width -| 4, 50))
        .render(a, content);
}
