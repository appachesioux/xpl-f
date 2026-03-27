const std = @import("std");
const linux = std.os.linux;
const entry_mod = @import("entry.zig");
const FileEntry = entry_mod.FileEntry;
const EntryKind = entry_mod.EntryKind;

pub const DirState = struct {
    path: []const u8,
    all_entries: std.ArrayList(FileEntry),
    filtered_entries: std.ArrayList(usize),
    name_arena: std.heap.ArenaAllocator,
    show_hidden: bool,
    search_query: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    current_uid: u32,

    // Edit mode state
    edit_names: std.ArrayList(std.ArrayList(u8)),
    has_edits: bool,

    pub fn init(allocator: std.mem.Allocator) DirState {
        return .{
            .path = "",
            .all_entries = .{},
            .filtered_entries = .{},
            .name_arena = std.heap.ArenaAllocator.init(allocator),
            .show_hidden = false,
            .search_query = .{},
            .allocator = allocator,
            .current_uid = std.posix.getuid(),
            .edit_names = .{},
            .has_edits = false,
        };
    }

    pub fn deinit(self: *DirState) void {
        self.all_entries.deinit(self.allocator);
        self.filtered_entries.deinit(self.allocator);
        self.name_arena.deinit();
        self.search_query.deinit(self.allocator);
        self.clear_edit_names();
        self.edit_names.deinit(self.allocator);
    }

    fn clear_edit_names(self: *DirState) void {
        for (self.edit_names.items) |*name| {
            name.deinit(self.allocator);
        }
        self.edit_names.clearRetainingCapacity();
    }

    pub fn scan(self: *DirState, path: []const u8) !void {
        _ = self.name_arena.reset(.retain_capacity);
        self.all_entries.clearRetainingCapacity();

        const arena_alloc = self.name_arena.allocator();
        self.path = try arena_alloc.dupe(u8, path);

        var uid_cache = UidCache.init(arena_alloc);

        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |e| {
            const name_z = try arena_alloc.dupeZ(u8, e.name);
            const name = name_z[0..e.name.len];

            var size: u64 = 0;
            var modified: i128 = 0;
            var is_executable = false;
            var mode: u32 = 0;
            var uid: u32 = 0;

            var stx = std.mem.zeroes(linux.Statx);
            const mask = linux.STATX_SIZE | linux.STATX_MODE | linux.STATX_MTIME | linux.STATX_UID;
            const rc = linux.statx(dir.fd, name_z, 0, mask, &stx);
            if (linux.E.init(rc) == .SUCCESS) {
                size = stx.size;
                modified = @as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec;
                is_executable = (stx.mode & 0o111) != 0;
                mode = @intCast(stx.mode & 0o7777);
                uid = stx.uid;
            }

            const owner = if (uid != self.current_uid)
                uid_cache.resolve(uid) catch ""
            else
                "";

            const kind: EntryKind = switch (e.kind) {
                .directory => .dir,
                .sym_link => .symlink,
                .file => .file,
                else => .other,
            };

            try self.all_entries.append(self.allocator, .{
                .name = name,
                .size = size,
                .modified = modified,
                .kind = kind,
                .is_executable = is_executable,
                .selected = false,
                .mode = mode,
                .uid = uid,
                .owner = owner,
            });
        }

        self.sort();
        try self.apply_filter();
    }

    fn sort(self: *DirState) void {
        std.mem.sortUnstable(FileEntry, self.all_entries.items, {}, FileEntry.lessThan);
    }

    pub fn apply_filter(self: *DirState) !void {
        self.filtered_entries.clearRetainingCapacity();

        for (self.all_entries.items, 0..) |e, i| {
            if (!self.show_hidden and e.name.len > 0 and e.name[0] == '.') continue;
            if (self.search_query.items.len > 0) {
                if (!fuzzy_match(e.name, self.search_query.items)) continue;
            }
            try self.filtered_entries.append(self.allocator, i);
        }
    }

    pub fn toggle_hidden(self: *DirState) !void {
        self.show_hidden = !self.show_hidden;
        try self.apply_filter();
    }

    pub fn get_entry(self: *const DirState, filtered_idx: usize) ?*const FileEntry {
        if (filtered_idx >= self.filtered_entries.items.len) return null;
        const real_idx = self.filtered_entries.items[filtered_idx];
        return &self.all_entries.items[real_idx];
    }

    pub fn get_entry_mut(self: *DirState, filtered_idx: usize) ?*FileEntry {
        if (filtered_idx >= self.filtered_entries.items.len) return null;
        const real_idx = self.filtered_entries.items[filtered_idx];
        return &self.all_entries.items[real_idx];
    }

    pub fn entry_count(self: *const DirState) usize {
        return self.filtered_entries.items.len;
    }

    // --- Edit mode ---

    pub fn enter_edit_mode(self: *DirState) !void {
        self.clear_edit_names();
        self.has_edits = false;

        for (self.filtered_entries.items) |real_idx| {
            const e = self.all_entries.items[real_idx];
            var name_buf: std.ArrayList(u8) = .{};
            try name_buf.appendSlice(self.allocator, e.name);
            try self.edit_names.append(self.allocator, name_buf);
        }
    }

    pub fn get_edit_name(self: *const DirState, filtered_idx: usize) ?[]const u8 {
        if (filtered_idx >= self.edit_names.items.len) return null;
        return self.edit_names.items[filtered_idx].items;
    }

    pub fn get_edit_name_mut(self: *DirState, filtered_idx: usize) ?*std.ArrayList(u8) {
        if (filtered_idx >= self.edit_names.items.len) return null;
        return &self.edit_names.items[filtered_idx];
    }

    pub fn apply_search_replace(self: *DirState, find: []const u8, replace_with: []const u8) !void {
        for (self.filtered_entries.items, 0..) |real_idx, i| {
            if (i >= self.edit_names.items.len) break;
            const original = self.all_entries.items[real_idx].name;
            var name = &self.edit_names.items[i];
            name.clearRetainingCapacity();

            if (find.len == 0) {
                try name.appendSlice(self.allocator, original);
                continue;
            }

            var pos: usize = 0;
            while (pos < original.len) {
                if (pos + find.len <= original.len and std.mem.eql(u8, original[pos .. pos + find.len], find)) {
                    try name.appendSlice(self.allocator, replace_with);
                    pos += find.len;
                } else {
                    try name.append(self.allocator, original[pos]);
                    pos += 1;
                }
            }
        }
    }

    pub fn has_selection(self: *const DirState) bool {
        for (self.filtered_entries.items) |real_idx| {
            if (self.all_entries.items[real_idx].selected) return true;
        }
        return false;
    }

    pub const EditOp = union(enum) {
        rename: struct { from: []const u8, to: []const u8 },
        delete: []const u8,
    };

    pub fn collect_edits(self: *DirState, alloc: std.mem.Allocator) !std.ArrayList(EditOp) {
        var ops: std.ArrayList(EditOp) = .{};

        for (self.filtered_entries.items, 0..) |real_idx, i| {
            if (i >= self.edit_names.items.len) break;
            const original = self.all_entries.items[real_idx].name;
            const edited = self.edit_names.items[i].items;

            if (edited.len > 0 and !std.mem.eql(u8, original, edited)) {
                try ops.append(alloc, .{ .rename = .{ .from = original, .to = edited } });
            }
        }

        return ops;
    }

};

pub fn recursive_walk(
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    base_path: []const u8,
    show_hidden: bool,
    max_results: usize,
) !std.ArrayList([]const u8) {
    var results: std.ArrayList([]const u8) = .{};
    const arena_alloc = arena.allocator();

    var dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch return results;
    defer dir.close();

    var walker = dir.walk(allocator) catch return results;
    defer walker.deinit();

    while (results.items.len < max_results) {
        const entry = walker.next() catch break;
        if (entry == null) break;
        const e = entry.?;

        // Skip hidden directories/files
        if (!show_hidden) {
            const basename = e.basename;
            if (basename.len > 0 and basename[0] == '.') continue;

            // Check if any path component is hidden
            var skip = false;
            var path_iter = std.mem.splitScalar(u8, e.path, '/');
            while (path_iter.next()) |component| {
                if (component.len > 0 and component[0] == '.') {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
        }

        // Skip known heavy directories
        const basename = e.basename;
        if (std.mem.eql(u8, basename, "node_modules") or
            std.mem.eql(u8, basename, "target") or
            std.mem.eql(u8, basename, "__pycache__"))
        {
            continue;
        }

        const path_dupe = arena_alloc.dupe(u8, e.path) catch break;
        results.append(allocator, path_dupe) catch break;
    }

    return results;
}

pub fn fuzzy_match_pub(name: []const u8, query: []const u8) bool {
    return fuzzy_match(name, query);
}

const UidCache = struct {
    map: std.AutoHashMapUnmanaged(u32, []const u8),
    alloc: std.mem.Allocator,
    passwd_loaded: bool,
    passwd_buf: ?[]const u8,

    fn init(alloc: std.mem.Allocator) UidCache {
        return .{
            .map = .{},
            .alloc = alloc,
            .passwd_loaded = false,
            .passwd_buf = null,
        };
    }

    fn load_passwd(self: *UidCache) void {
        if (self.passwd_loaded) return;
        self.passwd_loaded = true;

        const file = std.fs.openFileAbsolute("/etc/passwd", .{}) catch return;
        defer file.close();

        const content = file.readToEndAlloc(self.alloc, 1024 * 1024) catch return;
        self.passwd_buf = content;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ':');
            const name = fields.next() orelse continue;
            _ = fields.next(); // password
            const uid_str = fields.next() orelse continue;
            const uid = std.fmt.parseInt(u32, uid_str, 10) catch continue;
            self.map.put(self.alloc, uid, name) catch continue;
        }
    }

    fn resolve(self: *UidCache, uid: u32) ![]const u8 {
        self.load_passwd();
        if (self.map.get(uid)) |name| return name;
        const fallback = try std.fmt.allocPrint(self.alloc, "{d}", .{uid});
        self.map.put(self.alloc, uid, fallback) catch {};
        return fallback;
    }
};

fn fuzzy_match(name: []const u8, query: []const u8) bool {
    if (query.len > name.len) return false;
    for (0..name.len -| query.len + 1) |i| {
        var matched = true;
        for (query, 0..) |qc, j| {
            const nc = name[i + j];
            if (std.ascii.toLower(qc) != std.ascii.toLower(nc)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}
