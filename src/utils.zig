const std = @import("std");

pub fn relativeTime(seconds_ago: i64, buf: *[32]u8) []const u8 {
    if (seconds_ago <= 0) return "never";

    const s: u64 = @intCast(seconds_ago);

    if (s < 60) {
        return std.fmt.bufPrint(buf, "{d}s ago", .{s}) catch "?";
    } else if (s < 3600) {
        return std.fmt.bufPrint(buf, "{d}m ago", .{s / 60}) catch "?";
    } else if (s < 86400) {
        return std.fmt.bufPrint(buf, "{d}h ago", .{s / 3600}) catch "?";
    } else if (s < 604800) {
        return std.fmt.bufPrint(buf, "{d}d ago", .{s / 86400}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}w ago", .{s / 604800}) catch "?";
    }
}

pub fn relativeTimeFromTimestamp(timestamp: i64, buf: *[32]u8) []const u8 {
    if (timestamp == 0) return "never";
    const now = std.time.timestamp();
    const diff = now - timestamp;
    if (diff < 0) return "future";
    return relativeTime(diff, buf);
}

pub fn truncate(s: []const u8, max_len: usize, buf: []u8) []const u8 {
    if (s.len <= max_len) return s;
    if (max_len < 3) return s[0..max_len];

    const end = max_len - 2;
    @memcpy(buf[0..end], s[0..end]);
    buf[end] = '.';
    buf[end + 1] = '.';
    return buf[0 .. end + 2];
}
