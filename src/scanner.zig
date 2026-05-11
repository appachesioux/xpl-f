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

pub const CleanReason = enum {
    size_match,
    age_match,
    name_pattern,
    empty_dir,
    broken_link,
};

pub const SizeOp = enum { eq, ge, le };
pub const AgeOp = enum { gt, lt };

pub const SizeCond = struct {
    op: SizeOp,
    value: u64,

    pub fn matches(self: SizeCond, size: u64) bool {
        return switch (self.op) {
            .eq => size == self.value,
            .ge => size >= self.value,
            .le => size <= self.value,
        };
    }
};

pub const AgeCond = struct {
    op: AgeOp,
    days: u32,

    pub fn matches(self: AgeCond, mtime_secs: i64, now_secs: i64) bool {
        if (mtime_secs <= 0) return false;
        const age_secs: i64 = @as(i64, @intCast(self.days)) * 86400;
        const diff = now_secs - mtime_secs;
        return switch (self.op) {
            .gt => diff >= age_secs,
            .lt => diff < age_secs,
        };
    }
};

pub const CleanFilter = struct {
    size: ?SizeCond = null,
    age: ?AgeCond = null,
    name_patterns: bool = false,
    empty_dirs: bool = false,
    broken_symlinks: bool = false,

    pub fn any_active(self: CleanFilter) bool {
        return self.size != null or self.age != null or
            self.name_patterns or self.empty_dirs or self.broken_symlinks;
    }
};

pub const ParseError = error{
    Empty,
    BadOperator,
    BadNumber,
    BadSuffix,
    BadUnit,
};

/// Parses size expression: "[op]<number>[K|M|G]" — op default ">="
pub fn parseSizeExpr(input: []const u8) ParseError!SizeCond {
    var s = std.mem.trim(u8, input, " \t");
    if (s.len == 0) return ParseError.Empty;

    var op: SizeOp = .ge;
    if (std.mem.startsWith(u8, s, ">=")) {
        op = .ge;
        s = s[2..];
    } else if (std.mem.startsWith(u8, s, "<=")) {
        op = .le;
        s = s[2..];
    } else if (std.mem.startsWith(u8, s, "=")) {
        op = .eq;
        s = s[1..];
    } else if (s[0] == '>' or s[0] == '<') {
        return ParseError.BadOperator;
    }

    s = std.mem.trim(u8, s, " \t");
    if (s.len == 0) return ParseError.BadNumber;

    var mul: u64 = 1;
    var num_end = s.len;
    const last = s[s.len - 1];
    switch (last) {
        'K', 'k' => {
            mul = 1024;
            num_end -= 1;
        },
        'M', 'm' => {
            mul = 1024 * 1024;
            num_end -= 1;
        },
        'G', 'g' => {
            mul = 1024 * 1024 * 1024;
            num_end -= 1;
        },
        '0'...'9' => {},
        else => return ParseError.BadSuffix,
    }

    const num_str = std.mem.trim(u8, s[0..num_end], " \t");
    if (num_str.len == 0) return ParseError.BadNumber;
    const n = std.fmt.parseUnsigned(u64, num_str, 10) catch return ParseError.BadNumber;
    return .{ .op = op, .value = n *| mul };
}

/// Parses age expression: "[op]<number>d" — op default ">", suffix 'd' required
pub fn parseAgeExpr(input: []const u8) ParseError!AgeCond {
    var s = std.mem.trim(u8, input, " \t");
    if (s.len == 0) return ParseError.Empty;

    var op: AgeOp = .gt;
    if (std.mem.startsWith(u8, s, ">")) {
        op = .gt;
        s = s[1..];
    } else if (std.mem.startsWith(u8, s, "<")) {
        op = .lt;
        s = s[1..];
    }

    s = std.mem.trim(u8, s, " \t");
    if (s.len < 2) return ParseError.BadNumber;
    const last = s[s.len - 1];
    if (last != 'd' and last != 'D') return ParseError.BadUnit;

    const num_str = std.mem.trim(u8, s[0 .. s.len - 1], " \t");
    if (num_str.len == 0) return ParseError.BadNumber;
    const n = std.fmt.parseUnsigned(u32, num_str, 10) catch return ParseError.BadNumber;
    return .{ .op = op, .days = n };
}

pub const CleanItem = struct {
    path: []const u8,
    size: u64,
    modified: i128,
    kind: entry_mod.EntryKind,
    reason: CleanReason,
};

pub const CleanBatchResult = struct {
    items: std.ArrayList(CleanItem),
    arena: std.heap.ArenaAllocator,
    generation: u64,
    is_final: bool,
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    loop: *Loop,
    generation: std.atomic.Value(u64),
    find_generation: std.atomic.Value(u64),
    clean_generation: std.atomic.Value(u64),
    scan_thread: ?std.Thread,
    find_thread: ?std.Thread,
    clean_thread: ?std.Thread,

    const Loop = @import("vaxis").Loop(Event);

    pub fn init(allocator: std.mem.Allocator, loop: *Loop) Scanner {
        return .{
            .allocator = allocator,
            .loop = loop,
            .generation = std.atomic.Value(u64).init(0),
            .find_generation = std.atomic.Value(u64).init(0),
            .clean_generation = std.atomic.Value(u64).init(0),
            .scan_thread = null,
            .find_thread = null,
            .clean_thread = null,
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
        if (self.clean_thread) |t| {
            t.join();
            self.clean_thread = null;
        }
    }

    pub fn cancelFind(self: *Scanner) void {
        _ = self.find_generation.fetchAdd(1, .seq_cst);
        if (self.find_thread) |t| {
            t.join();
            self.find_thread = null;
        }
    }

    pub fn cancelClean(self: *Scanner) void {
        _ = self.clean_generation.fetchAdd(1, .seq_cst);
        if (self.clean_thread) |t| {
            t.join();
            self.clean_thread = null;
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

    // ─── CLEAN (recursive cleanup scan) ───

    pub fn requestClean(
        self: *Scanner,
        base_path: []const u8,
        show_hidden: bool,
        filter: CleanFilter,
        max_results: usize,
    ) void {
        if (self.clean_thread) |t| {
            _ = self.clean_generation.fetchAdd(1, .seq_cst);
            t.join();
            self.clean_thread = null;
        }

        const gen = self.clean_generation.fetchAdd(1, .seq_cst) + 1;
        const path_dupe = self.allocator.dupe(u8, base_path) catch return;

        self.clean_thread = std.Thread.spawn(.{}, cleanWorker, .{
            self.allocator,
            self.loop,
            &self.clean_generation,
            gen,
            path_dupe,
            show_hidden,
            filter,
            max_results,
        }) catch {
            self.allocator.free(path_dupe);
            return;
        };
    }

    const CLEAN_BATCH_SIZE: usize = 100;

    fn cleanWorker(
        allocator: std.mem.Allocator,
        loop: *Loop,
        generation: *std.atomic.Value(u64),
        expected_gen: u64,
        base_path_dupe: []const u8,
        show_hidden: bool,
        filter: CleanFilter,
        max_results: usize,
    ) void {
        defer allocator.free(base_path_dupe);

        var dir = std.fs.openDirAbsolute(base_path_dupe, .{ .iterate = true }) catch {
            postCleanFinal(loop, allocator, expected_gen);
            return;
        };
        defer dir.close();

        var walker = dir.walk(allocator) catch {
            postCleanFinal(loop, allocator, expected_gen);
            return;
        };
        defer walker.deinit();

        var batch_arena = std.heap.ArenaAllocator.init(allocator);
        var batch_items: std.ArrayList(CleanItem) = .{};
        var total: usize = 0;

        const now_secs: i64 = std.time.timestamp();

        while (total < max_results) {
            if (generation.load(.seq_cst) != expected_gen) {
                batch_items.deinit(allocator);
                batch_arena.deinit();
                return;
            }

            const next_or_err = walker.next();
            const entry_opt = next_or_err catch break;
            if (entry_opt == null) break;
            const e = entry_opt.?;

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

            const item_kind: entry_mod.EntryKind = switch (e.kind) {
                .directory => .dir,
                .sym_link => .symlink,
                .file => .file,
                else => .other,
            };

            const name_z: [*:0]const u8 = e.basename.ptr;

            var stx = std.mem.zeroes(linux.Statx);
            const mask = linux.STATX_SIZE | linux.STATX_MTIME | linux.STATX_MODE;
            const lst_rc = linux.statx(e.dir.fd, name_z, linux.AT.SYMLINK_NOFOLLOW, mask, &stx);
            const have_stat = linux.E.init(lst_rc) == .SUCCESS;

            const size: u64 = if (have_stat) stx.size else 0;
            const mtime: i128 = if (have_stat)
                @as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec
            else
                0;

            var reason: ?CleanReason = null;

            if (item_kind == .symlink and filter.broken_symlinks) {
                // Follow symlink — ENOENT means broken
                var stx2 = std.mem.zeroes(linux.Statx);
                const f_rc = linux.statx(e.dir.fd, name_z, 0, linux.STATX_MODE, &stx2);
                if (linux.E.init(f_rc) != .SUCCESS) {
                    reason = .broken_link;
                }
            } else if (item_kind == .dir and filter.empty_dirs) {
                if (isDirEmpty(e.dir, e.basename)) {
                    reason = .empty_dir;
                }
            } else if (item_kind == .file and have_stat) {
                if (filter.size) |cond| {
                    if (cond.matches(size)) reason = .size_match;
                }
                if (reason == null) {
                    if (filter.age) |cond| {
                        const mtime_secs: i64 = @intCast(@divFloor(mtime, std.time.ns_per_s));
                        if (cond.matches(mtime_secs, now_secs)) reason = .age_match;
                    }
                }
                if (reason == null and filter.name_patterns) {
                    if (matchJunkPattern(e.basename)) reason = .name_pattern;
                }
            }

            if (reason == null) continue;

            const arena_alloc = batch_arena.allocator();
            const path_dupe = arena_alloc.dupe(u8, e.path) catch break;
            batch_items.append(allocator, .{
                .path = path_dupe,
                .size = size,
                .modified = mtime,
                .kind = item_kind,
                .reason = reason.?,
            }) catch break;
            total += 1;

            if (batch_items.items.len >= CLEAN_BATCH_SIZE) {
                if (generation.load(.seq_cst) != expected_gen) {
                    batch_items.deinit(allocator);
                    batch_arena.deinit();
                    return;
                }
                loop.postEvent(.{ .clean_batch = .{
                    .items = batch_items,
                    .arena = batch_arena,
                    .generation = expected_gen,
                    .is_final = false,
                } });
                batch_arena = std.heap.ArenaAllocator.init(allocator);
                batch_items = .{};
            }
        }

        if (generation.load(.seq_cst) != expected_gen) {
            batch_items.deinit(allocator);
            batch_arena.deinit();
            return;
        }
        loop.postEvent(.{ .clean_batch = .{
            .items = batch_items,
            .arena = batch_arena,
            .generation = expected_gen,
            .is_final = true,
        } });
    }

    fn postCleanFinal(loop: *Loop, allocator: std.mem.Allocator, expected_gen: u64) void {
        _ = allocator;
        loop.postEvent(.{ .clean_batch = .{
            .items = .{},
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .generation = expected_gen,
            .is_final = true,
        } });
    }

    fn isDirEmpty(parent: std.fs.Dir, basename: []const u8) bool {
        var d = parent.openDir(basename, .{ .iterate = true }) catch return false;
        defer d.close();
        var it = d.iterate();
        const first = it.next() catch return false;
        return first == null;
    }

    fn matchJunkPattern(name: []const u8) bool {
        const exacts = [_][]const u8{ ".DS_Store", "Thumbs.db", "desktop.ini" };
        for (exacts) |x| {
            if (std.mem.eql(u8, name, x)) return true;
        }
        const suffixes = [_][]const u8{ "~", ".bak", ".tmp", ".swp", ".swo", ".pyc", ".pyo", ".class", ".orig", ".rej" };
        for (suffixes) |s| {
            if (name.len > s.len and std.mem.endsWith(u8, name, s)) return true;
        }
        // core.<digits>
        if (std.mem.startsWith(u8, name, "core.")) {
            const rest = name[5..];
            if (rest.len > 0) {
                var all_digits = true;
                for (rest) |c| {
                    if (c < '0' or c > '9') {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) return true;
            }
        }
        return false;
    }
};
