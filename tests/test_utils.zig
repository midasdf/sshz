const std = @import("std");
const utils = @import("utils");

test "relative time: seconds ago" {
    var buf: [32]u8 = undefined;
    const result = utils.relativeTime(30, &buf);
    try std.testing.expectEqualStrings("30s ago", result);
}

test "relative time: minutes ago" {
    var buf: [32]u8 = undefined;
    const result = utils.relativeTime(180, &buf);
    try std.testing.expectEqualStrings("3m ago", result);
}

test "relative time: hours ago" {
    var buf: [32]u8 = undefined;
    const result = utils.relativeTime(7200, &buf);
    try std.testing.expectEqualStrings("2h ago", result);
}

test "relative time: days ago" {
    var buf: [32]u8 = undefined;
    const result = utils.relativeTime(172800, &buf);
    try std.testing.expectEqualStrings("2d ago", result);
}

test "relative time: never" {
    var buf: [32]u8 = undefined;
    const result = utils.relativeTime(0, &buf);
    try std.testing.expectEqualStrings("never", result);
}

test "truncate string" {
    var buf: [16]u8 = undefined;
    const result = utils.truncate("staging.example.com", 15, &buf);
    try std.testing.expectEqualStrings("staging.examp..", result);
}

test "truncate short string unchanged" {
    var buf: [32]u8 = undefined;
    const result = utils.truncate("short", 15, &buf);
    try std.testing.expectEqualStrings("short", result);
}
