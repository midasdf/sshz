const std = @import("std");
const zz = @import("zigzag");
const ssh_config = @import("ssh_config");
const meta_mod = @import("meta");
const checker_mod = @import("checker");
const utils = @import("utils");
const host_list = @import("views/host_list.zig");
const host_form = @import("views/host_form.zig");
const help_view = @import("views/help.zig");
const forward_view = @import("views/forward.zig");

pub const Screen = enum {
    list,
    add_form,
    edit_form,
    forward_select,
    help,
};

pub const HostEntry = struct {
    config: ssh_config.Host,
    meta: ?meta_mod.HostMeta,
    status: checker_mod.HostStatus,
};

pub const Model = struct {
    screen: Screen = .list,
    hosts: std.ArrayList(HostEntry),
    config: ssh_config.Config,
    meta_store: meta_mod.MetaStore,
    config_path: []const u8,
    meta_path: []const u8,
    backup_dir: []const u8,
    result_queue: checker_mod.ResultQueue,
    status_checker: checker_mod.StatusChecker,
    selected: usize = 0,
    search_active: bool = false,
    search_text: std.ArrayList(u8),
    sort_mode: SortMode = .name,
    tag_filter: ?[]const u8 = null,
    all_tags: std.ArrayList([]const u8),
    tag_filter_index: usize = 0,
    notification: ?[]const u8 = null,
    notification_timer: u32 = 0,
    confirm_delete: bool = false,
    form_state: ?host_form.FormState = null,
    forward_state: ?forward_view.ForwardState = null,
    connect_host: ?[]const u8 = null,
    checker_generation: u32 = 0,
    pa: std.mem.Allocator,

    pub const SortMode = enum { name, recent, tag };

    pub const Msg = union(enum) {
        key: zz.msg.Key,
        tick: zz.msg.Tick,
    };

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        self.pa = ctx.persistent_allocator;

        self.hosts = .{};
        self.search_text = .{};
        self.all_tags = .{};

        // Load config
        self.config_path = ssh_config.defaultConfigPath(self.pa) catch "/dev/null";
        self.meta_path = meta_mod.defaultMetaPath(self.pa) catch "/dev/null";
        self.backup_dir = meta_mod.defaultBackupDir(self.pa) catch "/dev/null";

        self.config = ssh_config.readFile(self.pa, self.config_path) catch ssh_config.Config{
            .hosts = &.{},
            .raw_lines = &.{},
        };
        self.meta_store = meta_mod.readFile(self.pa, self.meta_path) catch meta_mod.MetaStore.initWith(self.pa);

        self.rebuildHostList();

        // Status checker
        self.result_queue = checker_mod.ResultQueue.init(self.pa);
        self.status_checker = checker_mod.StatusChecker.init(&self.result_queue, self.pa);
        self.startStatusChecks();
        self.collectTags();

        return zz.Cmd(Msg).everyMs(100);
    }

    pub fn deinit(self: *Model) void {
        self.status_checker.deinit();
        self.hosts.deinit(self.pa);
        self.search_text.deinit(self.pa);
        self.all_tags.deinit(self.pa);
        self.result_queue.deinit();
        if (self.form_state) |*fs| fs.deinit();
        if (self.forward_state) |*fs| fs.deinit(self.pa);
    }

    fn rebuildHostList(self: *Model) void {
        self.hosts.clearRetainingCapacity();
        for (self.config.hosts) |host| {
            if (host.is_wildcard) continue;
            const host_meta = self.meta_store.getHost(host.name);
            self.hosts.append(self.pa, .{
                .config = host,
                .meta = if (host_meta) |m| m.* else null,
                .status = .unknown,
            }) catch {};
        }
    }

    fn startStatusChecks(self: *Model) void {
        var requests: std.ArrayList(checker_mod.CheckRequest) = .{};
        defer requests.deinit(self.pa);

        for (self.hosts.items, 0..) |entry, i| {
            if (entry.config.proxy_jump != null) continue;
            requests.append(self.pa, .{
                .host_index = i,
                .hostname = ssh_config.Config.effectiveHostname(entry.config),
                .port = ssh_config.Config.effectivePort(entry.config),
            }) catch {};
            self.hosts.items[i].status = .checking;
        }

        if (requests.items.len > 0) {
            self.status_checker.checkAll(requests.items);
            self.checker_generation = self.status_checker.generation.load(.acquire);
        }
    }

    fn collectTags(self: *Model) void {
        self.all_tags.clearRetainingCapacity();
        var it = self.meta_store.entries.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.tags) |tag| {
                var found = false;
                for (self.all_tags.items) |existing| {
                    if (std.mem.eql(u8, existing, tag)) { found = true; break; }
                }
                if (!found) self.all_tags.append(self.pa, tag) catch {};
            }
        }
    }

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        _ = ctx;
        switch (msg) {
            .tick => {
                // Poll status results
                const results = self.result_queue.drain(self.pa);
                for (results) |r| {
                    // Discard stale results from previous check rounds
                    if (r.generation != self.checker_generation) continue;
                    if (r.host_index < self.hosts.items.len) {
                        self.hosts.items[r.host_index].status = r.status;
                    }
                }
                if (results.len > 0) self.pa.free(results);

                // Notification timer
                if (self.notification_timer > 0) {
                    self.notification_timer -= 1;
                    if (self.notification_timer == 0) self.notification = null;
                }
                return .none;
            },
            .key => |k| return self.handleKey(k),
        }
    }

    fn handleKey(self: *Model, k: zz.msg.Key) zz.Cmd(Msg) {
        // Form screens
        if (self.screen == .add_form or self.screen == .edit_form) {
            return self.handleFormKey(k);
        }

        // Forward selection
        if (self.screen == .forward_select) {
            return self.handleForwardKey(k);
        }

        // Help screen
        if (self.screen == .help) {
            switch (k.key) {
                .escape => self.screen = .list,
                .char => |c| if (c == '?') { self.screen = .list; },
                else => {},
            }
            return .none;
        }

        // Search mode
        if (self.search_active) {
            switch (k.key) {
                .escape => {
                    self.search_active = false;
                    self.search_text.clearRetainingCapacity();
                },
                .backspace => {
                    if (self.search_text.items.len > 0) _ = self.search_text.pop();
                },
                .enter => self.search_active = false,
                .char => |c| {
                    if (c < 128) self.search_text.append(self.pa, @intCast(c)) catch {};
                },
                else => {},
            }
            self.selected = 0;
            return .none;
        }

        // Delete confirmation
        if (self.confirm_delete) {
            switch (k.key) {
                .char => |c| switch (c) {
                    'y' => {
                        self.deleteSelectedHost();
                        self.confirm_delete = false;
                    },
                    'n' => self.confirm_delete = false,
                    else => {},
                },
                .escape => self.confirm_delete = false,
                else => {},
            }
            return .none;
        }

        // Normal list mode
        switch (k.key) {
            .char => |c| switch (c) {
                'q' => return .quit,
                'j' => self.moveDown(),
                'k' => self.moveUp(),
                '/' => {
                    self.search_active = true;
                    self.search_text.clearRetainingCapacity();
                },
                'a' => {
                    self.form_state = host_form.FormState.init(self.pa);
                    self.screen = .add_form;
                },
                'e' => {
                    if (self.hosts.items.len > 0 and self.selected < self.hosts.items.len) {
                        var form = host_form.FormState.init(self.pa);
                        const entry = self.hosts.items[self.selected];
                        form.editing_host = entry.config.name;
                        // Load values
                        form.fields[0].setValue(entry.config.name) catch {};
                        if (entry.config.hostname) |v| form.fields[1].setValue(v) catch {};
                        if (entry.config.user) |v| form.fields[2].setValue(v) catch {};
                        if (entry.config.port) |p| {
                            var buf: [8]u8 = undefined;
                            const ps = std.fmt.bufPrint(&buf, "{d}", .{p}) catch "22";
                            form.fields[3].setValue(ps) catch {};
                        }
                        if (entry.config.identity_file) |v| form.fields[4].setValue(v) catch {};
                        if (entry.config.proxy_jump) |v| form.fields[5].setValue(v) catch {};
                        self.form_state = form;
                        self.screen = .edit_form;
                    }
                },
                'd' => {
                    if (self.hosts.items.len > 0) self.confirm_delete = true;
                },
                'r' => self.startStatusChecks(),
                's' => self.cycleSortMode(),
                't' => self.cycleTagFilter(),
                'f' => {
                    if (self.selected < self.hosts.items.len) {
                        const entry = self.hosts.items[self.selected];
                        const fwds = if (entry.meta) |m| m.port_forwards else &.{};
                        self.forward_state = forward_view.ForwardState.init(self.pa, entry.config.name, fwds);
                        self.screen = .forward_select;
                    }
                },
                '?' => self.screen = .help,
                else => {},
            },
            .enter => {
                if (self.hosts.items.len > 0 and self.selected < self.hosts.items.len) {
                    self.connectToSelected();
                    return .quit;
                }
            },
            .up => self.moveUp(),
            .down => self.moveDown(),
            else => {},
        }
        return .none;
    }

    fn handleFormKey(self: *Model, k: zz.msg.Key) zz.Cmd(Msg) {
        var form = &(self.form_state orelse return .none);
        switch (k.key) {
            .escape => {
                form.deinit();
                self.form_state = null;
                self.screen = .list;
            },
            .enter => {
                self.saveForm();
                form.deinit();
                self.form_state = null;
                self.screen = .list;
            },
            .tab, .down => {
                if (k.modifiers.shift)
                    form.focusPrev()
                else
                    form.focusNext();
            },
            .up => form.focusPrev(),
            else => form.handleKey(k),
        }
        return .none;
    }

    fn handleForwardKey(self: *Model, k: zz.msg.Key) zz.Cmd(Msg) {
        var fwd = &(self.forward_state orelse return .none);
        switch (k.key) {
            .escape => {
                fwd.deinit(self.pa);
                self.forward_state = null;
                self.screen = .list;
            },
            .enter => {
                self.connectWithForwards();
                return .quit;
            },
            .space => fwd.toggle(),
            .up => fwd.moveUp(),
            .down => fwd.moveDown(),
            .char => |c| switch (c) {
                'k' => fwd.moveUp(),
                'j' => fwd.moveDown(),
                else => {},
            },
            else => {},
        }
        return .none;
    }

    fn moveUp(self: *Model) void {
        if (self.selected > 0) self.selected -= 1;
    }

    fn moveDown(self: *Model) void {
        if (self.selected + 1 < self.hosts.items.len) self.selected += 1;
    }

    fn cycleSortMode(self: *Model) void {
        self.sort_mode = switch (self.sort_mode) {
            .name => .recent,
            .recent => .tag,
            .tag => .name,
        };
        self.sortHosts();
    }

    fn sortHosts(self: *Model) void {
        switch (self.sort_mode) {
            .name => std.mem.sort(HostEntry, self.hosts.items, {}, struct {
                fn lt(_: void, a: HostEntry, b: HostEntry) bool {
                    return std.mem.order(u8, a.config.name, b.config.name) == .lt;
                }
            }.lt),
            .recent => std.mem.sort(HostEntry, self.hosts.items, {}, struct {
                fn lt(_: void, a: HostEntry, b: HostEntry) bool {
                    const at = if (a.meta) |m| m.last_connected else 0;
                    const bt = if (b.meta) |m| m.last_connected else 0;
                    return at > bt;
                }
            }.lt),
            .tag => std.mem.sort(HostEntry, self.hosts.items, {}, struct {
                fn lt(_: void, a: HostEntry, b: HostEntry) bool {
                    const atag = if (a.meta) |m| (if (m.tags.len > 0) m.tags[0] else "zzz") else "zzz";
                    const btag = if (b.meta) |m| (if (m.tags.len > 0) m.tags[0] else "zzz") else "zzz";
                    return std.mem.order(u8, atag, btag) == .lt;
                }
            }.lt),
        }
    }

    fn cycleTagFilter(self: *Model) void {
        if (self.all_tags.items.len == 0) return;
        self.tag_filter_index += 1;
        if (self.tag_filter_index > self.all_tags.items.len) self.tag_filter_index = 0;
        self.tag_filter = if (self.tag_filter_index == 0) null else self.all_tags.items[self.tag_filter_index - 1];
        self.selected = 0;
    }

    fn connectToSelected(self: *Model) void {
        if (self.selected >= self.hosts.items.len) return;
        const entry = self.hosts.items[self.selected];
        self.meta_store.recordConnection(self.pa, entry.config.name) catch {};
        meta_mod.writeFile(self.pa, &self.meta_store, self.meta_path) catch {};
        self.connect_host = self.pa.dupe(u8, entry.config.name) catch null;
    }

    fn connectWithForwards(self: *Model) void {
        // TODO: pass enabled forwards to connect
        self.connectToSelected();
    }

    fn saveForm(self: *Model) void {
        const form = &(self.form_state orelse return);

        // IMPORTANT: dupe values before form deinit
        const name = self.pa.dupe(u8, form.getValue(.name)) catch return;
        if (name.len == 0) return;

        const hostname_val = form.getValue(.hostname);
        const user_val = form.getValue(.user);
        const port_val = form.getValue(.port);
        const identity_val = form.getValue(.identity_file);
        const proxy_val = form.getValue(.proxy_jump);
        const tags_val = form.getValue(.tags);

        const new_host = ssh_config.Host{
            .name = name,
            .hostname = if (hostname_val.len > 0) (self.pa.dupe(u8, hostname_val) catch null) else null,
            .user = if (user_val.len > 0) (self.pa.dupe(u8, user_val) catch null) else null,
            .port = if (port_val.len > 0) std.fmt.parseInt(u16, port_val, 10) catch null else null,
            .identity_file = if (identity_val.len > 0) (self.pa.dupe(u8, identity_val) catch null) else null,
            .proxy_jump = if (proxy_val.len > 0) (self.pa.dupe(u8, proxy_val) catch null) else null,
        };

        // If editing, remove old host first
        if (form.editing_host) |old_name| {
            for (self.config.hosts, 0..) |h, ci| {
                if (std.mem.eql(u8, h.name, old_name)) {
                    ssh_config.removeHost(self.pa, &self.config, ci) catch {};
                    break;
                }
            }
        }

        ssh_config.addHost(self.pa, &self.config, new_host) catch {};
        ssh_config.writeFile(self.pa, &self.config, self.config_path, self.backup_dir) catch {};

        // Save tags
        if (tags_val.len > 0) {
            var tags: std.ArrayList([]const u8) = .{};
            defer tags.deinit(self.pa);
            var tag_it = std.mem.splitScalar(u8, tags_val, ',');
            while (tag_it.next()) |tag| {
                const trimmed = std.mem.trim(u8, tag, " ");
                if (trimmed.len > 0) tags.append(self.pa, trimmed) catch {};
            }
            self.meta_store.setTags(self.pa, name, tags.items) catch {};
        }
        meta_mod.writeFile(self.pa, &self.meta_store, self.meta_path) catch {};

        self.rebuildHostList();
        self.collectTags();
        self.notification = "Host saved!";
        self.notification_timer = 30;
    }

    fn deleteSelectedHost(self: *Model) void {
        if (self.selected >= self.hosts.items.len) return;

        var config_index: ?usize = null;
        var display_i: usize = 0;
        for (self.config.hosts, 0..) |h, ci| {
            if (h.is_wildcard) continue;
            if (display_i == self.selected) { config_index = ci; break; }
            display_i += 1;
        }

        if (config_index) |ci| {
            ssh_config.removeHost(self.pa, &self.config, ci) catch {};
            ssh_config.writeFile(self.pa, &self.config, self.config_path, self.backup_dir) catch {};
        }

        self.rebuildHostList();
        if (self.selected > 0 and self.selected >= self.hosts.items.len) self.selected -= 1;
        self.notification = "Host deleted";
        self.notification_timer = 30;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        return switch (self.screen) {
            .help => help_view.render(ctx) catch "Error",
            .add_form, .edit_form => if (self.form_state) |*form|
                host_form.render(form, ctx) catch "Error"
            else
                "Error",
            .forward_select => if (self.forward_state) |*fwd|
                forward_view.render(fwd, ctx) catch "Error"
            else
                "Error",
            .list => host_list.render(self, ctx) catch "Error",
        };
    }
};
