const std = @import("std");

// Stub - will be implemented in Task 4
pub const MetaStore = struct {
    pub fn initEmpty(allocator: std.mem.Allocator) MetaStore {
        _ = allocator;
        return .{};
    }
    pub fn deinit(self: *MetaStore, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};
