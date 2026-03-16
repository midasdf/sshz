const std = @import("std");

const version = "0.1.0";

pub fn main() !void {
    const file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    try w.interface.print("SSHZ v{s}\n", .{version});
    try w.interface.flush();
}
