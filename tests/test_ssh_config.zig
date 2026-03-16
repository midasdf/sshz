const std = @import("std");
const ssh_config = @import("ssh_config");

test "parse basic config" {
    const allocator = std.testing.allocator;
    const content = @embedFile("fixtures/basic_config");
    var config = try ssh_config.parse(allocator, content);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), config.hosts.len);

    const host0 = config.hosts[0];
    try std.testing.expectEqualStrings("myserver", host0.name);
    try std.testing.expectEqualStrings("10.0.0.1", host0.hostname.?);
    try std.testing.expectEqualStrings("root", host0.user.?);
    try std.testing.expectEqual(@as(u16, 22), host0.port.?);
    try std.testing.expectEqualStrings("~/.ssh/id_ed25519", host0.identity_file.?);

    const host1 = config.hosts[1];
    try std.testing.expectEqualStrings("staging", host1.name);
    try std.testing.expectEqual(@as(u16, 2222), host1.port.?);

    const host2 = config.hosts[2];
    try std.testing.expectEqualStrings("production", host2.name);
    try std.testing.expectEqualStrings("bastion", host2.proxy_jump.?);
}

test "parse config with wildcards flagged" {
    const allocator = std.testing.allocator;
    const content =
        \\Host *
        \\    ServerAliveInterval 60
        \\
        \\Host myserver
        \\    HostName 10.0.0.1
    ;
    var config = try ssh_config.parse(allocator, content);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), config.hosts.len);
    try std.testing.expect(config.hosts[0].is_wildcard);
    try std.testing.expect(!config.hosts[1].is_wildcard);
}

test "effective hostname falls back to host name" {
    const host = ssh_config.Host{ .name = "myserver" };
    try std.testing.expectEqualStrings("myserver", ssh_config.Config.effectiveHostname(host));
}

test "effective hostname uses HostName when set" {
    const host = ssh_config.Host{ .name = "myserver", .hostname = "10.0.0.1" };
    try std.testing.expectEqualStrings("10.0.0.1", ssh_config.Config.effectiveHostname(host));
}

test "find host case insensitive" {
    const allocator = std.testing.allocator;
    const content =
        \\Host MyServer
        \\    HostName 10.0.0.1
    ;
    var config = try ssh_config.parse(allocator, content);
    defer config.deinit(allocator);

    try std.testing.expect(config.findHost("myserver") != null);
    try std.testing.expect(config.findHost("MYSERVER") != null);
    try std.testing.expect(config.findHost("unknown") == null);
}

test "round-trip: parse then serialize preserves content" {
    const allocator = std.testing.allocator;
    const content =
        \\# My SSH config
        \\
        \\Host myserver
        \\    HostName 10.0.0.1
        \\    User root
        \\    Port 22
    ;
    var config = try ssh_config.parse(allocator, content);
    defer config.deinit(allocator);

    const output = try ssh_config.serialize(allocator, &config);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "# My SSH config") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Host myserver") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "    HostName 10.0.0.1") != null);
}

test "parse config with Match block skipped" {
    const allocator = std.testing.allocator;
    const content =
        \\Host myserver
        \\    HostName 10.0.0.1
        \\
        \\Match host *.example.com
        \\    User deploy
        \\
        \\Host staging
        \\    HostName staging.example.com
    ;
    var config = try ssh_config.parse(allocator, content);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), config.hosts.len);
    try std.testing.expectEqualStrings("myserver", config.hosts[0].name);
    try std.testing.expectEqualStrings("staging", config.hosts[1].name);
}
