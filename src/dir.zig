const std = @import("std");
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

        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |e| {
            const name = try arena_alloc.dupe(u8, e.name);

            var size: u64 = 0;
            var modified: i128 = 0;
            var is_executable = false;

            const stat = dir.statFile(e.name) catch null;
            if (stat) |s| {
                size = s.size;
                modified = s.mtime;
                is_executable = (s.mode & 0o111) != 0;
            }

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

    pub fn mark_edit_delete(self: *DirState, filtered_idx: usize) void {
        if (filtered_idx >= self.edit_names.items.len) return;
        self.edit_names.items[filtered_idx].clearRetainingCapacity();
        self.has_edits = true;
    }

    pub fn mark_edit_delete_selected(self: *DirState) bool {
        var any = false;
        for (self.filtered_entries.items, 0..) |real_idx, i| {
            if (i >= self.edit_names.items.len) break;
            if (self.all_entries.items[real_idx].selected) {
                self.edit_names.items[i].clearRetainingCapacity();
                self.has_edits = true;
                any = true;
            }
        }
        return any;
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

            if (edited.len == 0) {
                try ops.append(alloc, .{ .delete = original });
            } else if (!std.mem.eql(u8, original, edited)) {
                try ops.append(alloc, .{ .rename = .{ .from = original, .to = edited } });
            }
        }

        return ops;
    }

    pub fn apply_edits(self: *DirState) !usize {
        var ops = try self.collect_edits(self.allocator);
        defer ops.deinit(self.allocator);

        var applied: usize = 0;
        var dir = try std.fs.openDirAbsolute(self.path, .{});
        defer dir.close();

        for (ops.items) |op| {
            switch (op) {
                .rename => |r| {
                    dir.rename(r.from, r.to) catch continue;
                    applied += 1;
                },
                .delete => |name| {
                    dir.deleteFile(name) catch {
                        dir.deleteDir(name) catch continue;
                    };
                    applied += 1;
                },
            }
        }

        const path_copy = try self.allocator.dupe(u8, self.path);
        defer self.allocator.free(path_copy);
        try self.scan(path_copy);

        return applied;
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
