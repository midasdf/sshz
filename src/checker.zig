const std = @import("std");

pub const HostStatus = enum {
    unknown,
    checking,
    online,
    offline,
};

pub const CheckResult = struct {
    host_index: usize,
    status: HostStatus,
    generation: u32 = 0,
};

pub const CheckRequest = struct {
    host_index: usize,
    hostname: []const u8,
    port: u16,
};

pub const ResultQueue = struct {
    mutex: std.Thread.Mutex = .{},
    results: std.ArrayList(CheckResult) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ResultQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ResultQueue) void {
        self.results.deinit(self.allocator);
    }

    pub fn push(self: *ResultQueue, result: CheckResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.results.append(self.allocator, result) catch {};
    }

    pub fn drain(self: *ResultQueue, allocator: std.mem.Allocator) []CheckResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.results.items.len == 0) return &.{};
        return self.results.toOwnedSlice(allocator) catch return &.{};
    }
};

pub const StatusChecker = struct {
    queue: *ResultQueue,
    active_count: std.atomic.Value(u32),
    max_concurrent: u32 = 3,
    shutdown: std.atomic.Value(bool),
    threads: std.ArrayList(std.Thread) = .{},
    generation: std.atomic.Value(u32),
    allocator: std.mem.Allocator,

    pub fn init(queue: *ResultQueue, allocator: std.mem.Allocator) StatusChecker {
        return .{
            .queue = queue,
            .active_count = std.atomic.Value(u32).init(0),
            .shutdown = std.atomic.Value(bool).init(false),
            .generation = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StatusChecker) void {
        self.shutdown.store(true, .release);
        self.joinAllThreads();
        self.threads.deinit(self.allocator);
    }

    fn joinAllThreads(self: *StatusChecker) void {
        for (self.threads.items) |t| t.join();
        self.threads.clearRetainingCapacity();
    }

    /// Wait for any in-flight checks, then start a new round.
    pub fn checkAll(self: *StatusChecker, requests: []const CheckRequest) void {
        // Join previous round's threads before starting new ones
        self.joinAllThreads();
        // Increment generation so any lingering results are discarded
        const gen = self.generation.fetchAdd(1, .release) +% 1;

        for (requests) |req| {
            if (self.shutdown.load(.acquire)) return;

            while (self.active_count.load(.acquire) >= self.max_concurrent) {
                if (self.shutdown.load(.acquire)) return;
                std.Thread.yield() catch {};
            }

            _ = self.active_count.fetchAdd(1, .release);

            const thread = std.Thread.spawn(.{}, checkWorker, .{
                self,
                req.host_index,
                req.hostname,
                req.port,
                gen,
            }) catch {
                self.queue.push(.{ .host_index = req.host_index, .status = .offline, .generation = gen });
                _ = self.active_count.fetchSub(1, .release);
                continue;
            };
            self.threads.append(self.allocator, thread) catch {
                thread.join();
            };
        }
    }

    fn checkWorker(self: *StatusChecker, host_index: usize, hostname: []const u8, port: u16, gen: u32) void {
        defer _ = self.active_count.fetchSub(1, .release);
        if (self.shutdown.load(.acquire)) return;

        const status = tcpCheck(hostname, port);
        self.queue.push(.{ .host_index = host_index, .status = status, .generation = gen });
    }
};

fn tcpCheck(hostname: []const u8, port: u16) HostStatus {
    const stream = std.net.tcpConnectToHost(std.heap.page_allocator, hostname, port) catch return .offline;
    stream.close();
    return .online;
}
