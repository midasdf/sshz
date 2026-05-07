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
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    results: std.ArrayList(CheckResult) = .empty,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ResultQueue {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *ResultQueue) void {
        self.results.deinit(self.allocator);
    }

    pub fn push(self: *ResultQueue, result: CheckResult) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.results.append(self.allocator, result) catch {};
    }

    pub fn drain(self: *ResultQueue, allocator: std.mem.Allocator) []CheckResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.results.items.len == 0) return &.{};
        return self.results.toOwnedSlice(allocator) catch return &.{};
    }
};

pub const StatusChecker = struct {
    queue: *ResultQueue,
    active_count: std.atomic.Value(u32),
    max_concurrent: u32 = 3,
    shutdown: std.atomic.Value(bool),
    threads: std.ArrayList(std.Thread) = .empty,
    threads_mutex: std.Io.Mutex = std.Io.Mutex.init,
    dispatcher_thread: ?std.Thread = null,
    generation: std.atomic.Value(u32),
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(queue: *ResultQueue, allocator: std.mem.Allocator, io: std.Io) StatusChecker {
        return .{
            .queue = queue,
            .active_count = std.atomic.Value(u32).init(0),
            .shutdown = std.atomic.Value(bool).init(false),
            .generation = std.atomic.Value(u32).init(0),
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *StatusChecker) void {
        self.shutdown.store(true, .release);
        if (self.dispatcher_thread) |dt| {
            dt.join();
            self.dispatcher_thread = null;
        }
        self.joinAllThreads();
        self.threads.deinit(self.allocator);
    }

    fn joinAllThreads(self: *StatusChecker) void {
        self.threads_mutex.lockUncancelable(self.io);
        const threads = self.threads.toOwnedSlice(self.allocator) catch return;
        self.threads_mutex.unlock(self.io);
        for (threads) |t| t.join();
        self.allocator.free(threads);
    }

    /// Start a new round of checks. Returns immediately (non-blocking).
    pub fn checkAll(self: *StatusChecker, requests: []const CheckRequest) void {
        // Join previous dispatcher if still running
        if (self.dispatcher_thread) |dt| {
            dt.join();
            self.dispatcher_thread = null;
        }
        self.joinAllThreads();
        // Increment generation so any lingering results are discarded
        const gen = self.generation.fetchAdd(1, .release) +% 1;

        // Copy requests so dispatcher thread owns the data
        const owned_requests = self.allocator.dupe(CheckRequest, requests) catch return;

        self.dispatcher_thread = std.Thread.spawn(.{}, dispatchWorkers, .{
            self, owned_requests, gen,
        }) catch {
            self.allocator.free(owned_requests);
            return;
        };
    }

    fn dispatchWorkers(self: *StatusChecker, requests: []const CheckRequest, gen: u32) void {
        defer self.allocator.free(requests);

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
            self.threads_mutex.lockUncancelable(self.io);
            self.threads.append(self.allocator, thread) catch {
                self.threads_mutex.unlock(self.io);
                thread.join();
                continue;
            };
            self.threads_mutex.unlock(self.io);
        }
    }

    fn checkWorker(self: *StatusChecker, host_index: usize, hostname: []const u8, port: u16, gen: u32) void {
        defer _ = self.active_count.fetchSub(1, .release);
        if (self.shutdown.load(.acquire)) return;

        const status = tcpCheck(self.io, hostname, port);
        self.queue.push(.{ .host_index = host_index, .status = status, .generation = gen });
    }
};

fn tcpCheck(io: std.Io, hostname: []const u8, port: u16) HostStatus {
    const host = std.Io.net.HostName.init(hostname) catch return .offline;
    const stream = host.connect(io, port, .{}) catch return .offline;
    stream.close(io);
    return .online;
}
