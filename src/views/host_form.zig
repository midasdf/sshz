const std = @import("std");
const zz = @import("zigzag");

pub const FormField = enum(usize) {
    name = 0,
    hostname = 1,
    user = 2,
    port = 3,
    identity_file = 4,
    proxy_jump = 5,
    tags = 6,
};

pub const field_count = 7;

pub const FormState = struct {
    fields: [field_count]zz.TextInput,
    focused: usize = 0,
    editing_host: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) FormState {
        const placeholders = [field_count][]const u8{
            "Host name",
            "IP/hostname",
            "username",
            "22",
            "~/.ssh/id_ed25519",
            "bastion-host",
            "tag1, tag2",
        };

        var state: FormState = .{ .fields = undefined };

        for (0..field_count) |i| {
            state.fields[i] = zz.TextInput.init(allocator);
            state.fields[i].setPlaceholder(placeholders[i]);
            state.fields[i].setWidth(30);
        }

        state.fields[0].focus();
        return state;
    }

    pub fn deinit(self: *FormState) void {
        for (&self.fields) |*f| f.deinit();
    }

    pub fn focusNext(self: *FormState) void {
        self.fields[self.focused].blur();
        self.focused = (self.focused + 1) % field_count;
        self.fields[self.focused].focus();
    }

    pub fn focusPrev(self: *FormState) void {
        self.fields[self.focused].blur();
        self.focused = if (self.focused == 0) field_count - 1 else self.focused - 1;
        self.fields[self.focused].focus();
    }

    pub fn handleKey(self: *FormState, k: zz.msg.Key) void {
        self.fields[self.focused].handleKey(k);
    }

    pub fn getValue(self: *const FormState, comptime field: FormField) []const u8 {
        return self.fields[@intFromEnum(field)].getValue();
    }
};

pub fn render(form: *const FormState, ctx: *const zz.Context) ![]const u8 {
    const a = ctx.allocator;

    const title_text = if (form.editing_host != null) " Edit Host" else " Add Host";
    const title_style = (zz.Style{}).bold(true).fg(zz.Color.cyan());
    const title = try title_style.render(a, title_text);

    const dim = (zz.Style{}).fg(zz.Color.gray(12));
    const sep_chars = try a.alloc(u8, @min(ctx.width, 60));
    @memset(sep_chars, '-');
    const sep = try dim.render(a, sep_chars);

    const field_labels = [field_count][]const u8{
        " Name:         ",
        " HostName:     ",
        " User:         ",
        " Port:         ",
        " IdentityFile: ",
        " ProxyJump:    ",
        " Tags:         ",
    };

    const label_style = (zz.Style{}).fg(zz.Color.white()).bold(true);
    const focus_indicator = (zz.Style{}).fg(zz.Color.cyan()).bold(true);

    var lines: std.ArrayList([]const u8) = .{};
    defer lines.deinit(a);
    try lines.append(a, title);
    try lines.append(a, sep);

    for (0..field_count) |i| {
        const indicator = if (i == form.focused)
            try focus_indicator.render(a, ">")
        else
            " ";
        const label = try label_style.render(a, field_labels[i]);
        const field_view = try form.fields[i].view(a);

        const row = try zz.joinHorizontal(a, &.{ indicator, label, field_view });
        try lines.append(a, row);
    }

    try lines.append(a, sep);
    try lines.append(a, try dim.render(a, " Tab: next  Shift+Tab: prev  Enter: save  Esc: cancel"));

    return try zz.joinVertical(a, lines.items);
}
