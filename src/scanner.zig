const std = @import("std");
const linux = std.os.linux;
const entry_mod = @import("entry.zig");
const FileEntry = entry_mod.FileEntry;
const EntryKind = entry_mod.EntryKind;
const dir_mod = @import("dir.zig");

// Import Event from app.zig
const app_mod = @import("app.zig");
const Event = app_mod.Event;

pub const ScanTarget = enum { main, dest };

pub const ScanResult = struct {
    target: ScanTarget,
    path: []const u8,
    all_entries: std.ArrayList(FileEntry),
    name_arena: std.heap.ArenaAllocator,
    generation: u64,
};

pub const FindBatchResult = struct {
    paths: std.ArrayList([]const u8),
    arena: std.heap.ArenaAllocator,
    generation: u64,
    is_final: bool,
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    loop: *Loop,
    generation: std.atomic.Value(u64),
    find_generation: std.atomic.Value(u64),
    scan_thread: ?std.Thread,
    find_thread: ?std.Thread,

    const Loop = @import("vaxis").Loop(Event);

    pub fn init(allocator: std.mem.Allocator, loop: *Loop) Scanner {
        return .{
            .allocator = allocator,
            .loop = loop,
            .generation = std.atomic.Value(u64).init(0),
            .find_generation = std.atomic.Value(u64).init(0),
            .scan_thread = null,
            .find_thread = null,
        };
    }

    pub fn deinit(self: *Scanner) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        if (self.find_thread) |t| {
            t.join();
            self.find_thread = null;
        }
    }

    pub fn cancelFind(self: *Scanner) void {
        _ = self.find_generation.fetchAdd(1, .seq_cst);
        if (self.find_thread) |t| {
            t.join();
            self.find_thread = null;
        }
    }

    pub fn requestScan(
        self: *Scanner,
        path: []const u8,
        target: ScanTarget,
        current_uid: u32,
        show_hidden: bool,
    ) void {
        // Join previous thread if still running
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }

        // Bump generation to invalidate any in-flight results
        const gen = self.generation.fetchAdd(1, .seq_cst) + 1;

        // Dupe path for the thread (freed by thread on completion)
        const path_dupe = self.allocator.dupe(u8, path) catch return;

        self.scan_thread = std.Thread.spawn(.{}, scanWorker, .{
            self.allocator,
            self.loop,
            &self.generation,
            gen,
            path_dupe,
            target,
            current_uid,
            show_hidden,
        }) catch {
            self.allocator.free(path_dupe);
            return;
        };
    }

    fn scanWorker(
        allocator: std.mem.Allocator,
        loop: *Loop,
        generation: *std.atomic.Value(u64),
        expected_gen: u64,
        path_dupe: []const u8,
        target: ScanTarget,
        current_uid: u32,
        show_hidden: bool,
    ) void {
        var name_arena = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = name_arena.allocator();

        // Dupe path into arena so it lives with the result
        const path = arena_alloc.dupe(u8, path_dupe) catch {
            allocator.free(path_dupe);
            name_arena.deinit();
            return;
        };
        allocator.free(path_dupe);

        var all_entries: std.ArrayList(FileEntry) = .{};

        // Do the actual scanning
        scanDir(allocator, arena_alloc, path, current_uid, show_hidden, &all_entries) catch {
            // On error, clean up and discard
            all_entries.deinit(allocator);
            name_arena.deinit();
            return;
        };

        // Sort
        std.mem.sortUnstable(FileEntry, all_entries.items, {}, FileEntry.lessThan);

        // Check if still relevant before posting
        if (generation.load(.seq_cst) != expected_gen) {
            all_entries.deinit(allocator);
            name_arena.deinit();
            return;
        }

        // Post result to main thread
        loop.postEvent(.{ .scan_complete = .{
            .target = target,
            .path = path,
            .all_entries = all_entries,
            .name_arena = name_arena,
            .generation = expected_gen,
        } });
    }

    fn scanDir(
        allocator: std.mem.Allocator,
        arena_alloc: std.mem.Allocator,
        path: []const u8,
        current_uid: u32,
        show_hidden: bool,
        all_entries: *std.ArrayList(FileEntry),
    ) !void {
        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();

        var uid_cache = dir_mod.UidCache.init(arena_alloc);

        var iter = dir.iterate();
        while (try iter.next()) |e| {
            // Pre-filter hidden files to avoid unnecessary statx
            if (!show_hidden and e.name.len > 0 and e.name[0] == '.') continue;

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

            const owner = if (uid != current_uid)
                uid_cache.resolve(uid) catch ""
            else
                "";

            const kind: EntryKind = switch (e.kind) {
                .directory => .dir,
                .sym_link => .symlink,
                .file => .file,
                else => .other,
            };

            try all_entries.append(allocator, .{
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
    }

    pub fn requestFind(
        self: *Scanner,
        base_path: []const u8,
        show_hidden: bool,
        max_results: usize,
    ) void {
        // Cancel and join previous find thread
        if (self.find_thread) |t| {
            _ = self.find_generation.fetchAdd(1, .seq_cst);
            t.join();
            self.find_thread = null;
        }

        const gen = self.find_generation.fetchAdd(1, .seq_cst) + 1;
        const path_dupe = self.allocator.dupe(u8, base_path) catch return;

        self.find_thread = std.Thread.spawn(.{}, findWorker, .{
            self.allocator,
            self.loop,
            &self.find_generation,
            gen,
            path_dupe,
            show_hidden,
            max_results,
        }) catch {
            self.allocator.free(path_dupe);
            return;
        };
    }

    const FIND_BATCH_SIZE: usize = 200;

    fn findWorker(
        allocator: std.mem.Allocator,
        loop: *Loop,
        generation: *std.atomic.Value(u64),
        expected_gen: u64,
        base_path_dupe: []const u8,
        show_hidden: bool,
        max_results: usize,
    ) void {
        defer allocator.free(base_path_dupe);

        var dir = std.fs.openDirAbsolute(base_path_dupe, .{ .iterate = true }) catch return;
        defer dir.close();

        var walker = dir.walk(allocator) catch return;
        defer walker.deinit();

        var batch_arena = std.heap.ArenaAllocator.init(allocator);
        var batch_paths: std.ArrayList([]const u8) = .{};
        var total: usize = 0;

        while (total < max_results) {
            // Check cancellation
            if (generation.load(.seq_cst) != expected_gen) {
                batch_paths.deinit(allocator);
                batch_arena.deinit();
                return;
            }

            const entry = walker.next() catch break;
            if (entry == null) break;
            const e = entry.?;

            // Skip hidden
            if (!show_hidden) {
                if (e.basename.len > 0 and e.basename[0] == '.') continue;
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
            if (std.mem.eql(u8, e.basename, "node_modules") or
                std.mem.eql(u8, e.basename, "target") or
                std.mem.eql(u8, e.basename, "__pycache__"))
            {
                continue;
            }

            const arena_alloc = batch_arena.allocator();
            const path_dupe = arena_alloc.dupe(u8, e.path) catch break;
            batch_paths.append(allocator, path_dupe) catch break;
            total += 1;

            // Post batch when full
            if (batch_paths.items.len >= FIND_BATCH_SIZE) {
                if (generation.load(.seq_cst) != expected_gen) {
                    batch_paths.deinit(allocator);
                    batch_arena.deinit();
                    return;
                }
                loop.postEvent(.{ .find_batch = .{
                    .paths = batch_paths,
                    .arena = batch_arena,
                    .generation = expected_gen,
                    .is_final = false,
                } });
                // Start fresh batch
                batch_arena = std.heap.ArenaAllocator.init(allocator);
                batch_paths = .{};
            }
        }

        // Post final batch (may be empty)
        if (generation.load(.seq_cst) != expected_gen) {
            batch_paths.deinit(allocator);
            batch_arena.deinit();
            return;
        }
        loop.postEvent(.{ .find_batch = .{
            .paths = batch_paths,
            .arena = batch_arena,
            .generation = expected_gen,
            .is_final = true,
        } });
    }
};
