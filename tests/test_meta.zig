const std = @import("std");
const meta = @import("meta");

test "parse meta.json" {
    const allocator = std.testing.allocator;
    const content = @embedFile("fixtures/meta.json");
    var store = try meta.parse(allocator, content);
    defer store.deinit(allocator);

    const host = store.getHost("myserver");
    try std.testing.expect(host != null);

    const h = host.?;
    try std.testing.expectEqual(@as(usize, 2), h.tags.len);
    try std.testing.expectEqualStrings("work", h.tags[0]);
    try std.testing.expectEqual(@as(u32, 42), h.connect_count);
    try std.testing.expectEqual(@as(usize, 1), h.port_forwards.len);
    try std.testing.expectEqualStrings("local", h.port_forwards[0].forward_type);
}

test "record connection creates new host entry" {
    const allocator = std.testing.allocator;
    var store = meta.MetaStore.initWith(allocator);
    defer store.deinit(allocator);

    try store.recordConnection(allocator, "newhost");

    const host = store.getHost("newhost");
    try std.testing.expect(host != null);
    try std.testing.expectEqual(@as(u32, 1), host.?.connect_count);
    try std.testing.expect(host.?.last_connected > 0);
}

test "record connection increments existing count" {
    const allocator = std.testing.allocator;
    var store = meta.MetaStore.initWith(allocator);
    defer store.deinit(allocator);

    try store.recordConnection(allocator, "host1");
    try store.recordConnection(allocator, "host1");

    const host = store.getHost("host1");
    try std.testing.expectEqual(@as(u32, 2), host.?.connect_count);
}

test "serialize and parse round-trip" {
    const allocator = std.testing.allocator;
    var store = meta.MetaStore.initWith(allocator);
    defer store.deinit(allocator);

    try store.recordConnection(allocator, "roundtrip");
    const tags = [_][]const u8{ "dev", "local" };
    try store.setTags(allocator, "roundtrip", &tags);

    const serialized = try meta.serialize(allocator, &store);
    defer allocator.free(serialized);

    var store2 = try meta.parse(allocator, serialized);
    defer store2.deinit(allocator);

    const host = store2.getHost("roundtrip");
    try std.testing.expect(host != null);
    try std.testing.expectEqual(@as(u32, 1), host.?.connect_count);
    try std.testing.expectEqual(@as(usize, 2), host.?.tags.len);
}
