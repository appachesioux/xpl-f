const std = @import("std");
const vaxis = @import("vaxis");
const dir_mod = @import("dir.zig");
const mode_mod = @import("mode.zig");
const render = @import("render.zig");
const style = @import("style.zig");

const Vaxis = vaxis.Vaxis;
const Tty = vaxis.Tty;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    tty: Tty,
    vx: Vaxis,
    loop: vaxis.Loop(Event),
    tty_buf: [4096]u8,
    dir_state: dir_mod.DirState,

    cursor: usize,
    scroll_offset: usize,

    mode: mode_mod.Mode,

    edit_cursor_col: usize,

    search_buf: std.ArrayList(u8),

    replace_find_buf: std.ArrayList(u8),
    replace_with_buf: std.ArrayList(u8),
    replace_field: mode_mod.ReplaceField,

    message: ?[]const u8,
    message_buf: [256]u8,

    confirm_ops: ?std.ArrayList(dir_mod.DirState.EditOp),

    preview_lines: std.ArrayList([]const u8),
    preview_scroll: usize,
    preview_title: [256]u8,
    preview_title_len: usize,
    preview_is_binary: bool,
    preview_is_dir: bool,
    preview_total_lines: usize,

    frame_arena: std.heap.ArenaAllocator,

    // Create mode
    create_buf: std.ArrayList(u8),

    // Clipboard
    clip_entries: std.ArrayList([]const u8), // full paths
    clip_op: mode_mod.ClipOp,

    // Find mode (recursive search)
    find_buf: std.ArrayList(u8),
    find_all_paths: std.ArrayList([]const u8),
    find_filtered: std.ArrayList(usize),
    find_cursor: usize,
    find_scroll: usize,
    find_arena: std.heap.ArenaAllocator,
    find_saved_path: ?[]const u8,
    find_saved_cursor: usize,
    find_saved_scroll: usize,

    // Bookmark mode
    bookmarks: std.ArrayList([]const u8),
    bookmark_cursor: usize,
    bookmark_scroll: usize,

    // Tree view
    show_tree: bool,
    tree_lines: std.ArrayList([]const u8),
    tree_scroll: usize,
    tree_total_lines: usize,

    // Dual-panel (destination panel)
    dual_panel: bool,
    dest_active: bool, // true = destination panel has focus
    dest_state: dir_mod.DirState,
    dest_cursor: usize,
    dest_scroll: usize,

    should_quit: bool,

    pub fn init(allocator: std.mem.Allocator, initial_dir: ?[]const u8) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .tty = undefined,
            .vx = undefined,
            .loop = undefined,
            .tty_buf = undefined,
            .dir_state = dir_mod.DirState.init(allocator),
            .cursor = 0,
            .scroll_offset = 0,
            .mode = .normal,
            .edit_cursor_col = 0,
            .search_buf = .{},
            .replace_find_buf = .{},
            .replace_with_buf = .{},
            .replace_field = .find,
            .message = null,
            .message_buf = undefined,
            .confirm_ops = null,
            .preview_lines = .{},
            .preview_scroll = 0,
            .preview_title = undefined,
            .preview_title_len = 0,
            .preview_is_binary = false,
            .preview_is_dir = false,
            .preview_total_lines = 0,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .create_buf = .{},
            .clip_entries = .{},
            .clip_op = .none,
            .find_buf = .{},
            .find_all_paths = .{},
            .find_filtered = .{},
            .find_cursor = 0,
            .find_scroll = 0,
            .find_arena = std.heap.ArenaAllocator.init(allocator),
            .find_saved_path = null,
            .find_saved_cursor = 0,
            .find_saved_scroll = 0,
            .bookmarks = .{},
            .bookmark_cursor = 0,
            .bookmark_scroll = 0,
            .show_tree = false,
            .tree_lines = .{},
            .tree_scroll = 0,
            .tree_total_lines = 0,
            .dual_panel = false,
            .dest_active = false,
            .dest_state = dir_mod.DirState.init(allocator),
            .dest_cursor = 0,
            .dest_scroll = 0,
            .should_quit = false,
        };

        // Init tty with buffer that lives in self
        self.tty = try Tty.init(&self.tty_buf);
        self.vx = try Vaxis.init(allocator, .{});

        // Loop references self.vx and self.tty via pointers — stable since self is heap-allocated
        self.loop = .{ .vaxis = &self.vx, .tty = &self.tty };
        try self.loop.init();
        try self.loop.start();

        const writer = self.tty.writer();
        try self.vx.enterAltScreen(writer);

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const start_dir = initial_dir orelse ".";
        const resolved = try std.fs.cwd().realpath(start_dir, &path_buf);
        try self.dir_state.scan(resolved);

        self.load_bookmarks();

        return self;
    }

    pub fn deinit(self: *App) void {
        self.search_buf.deinit(self.allocator);
        self.replace_find_buf.deinit(self.allocator);
        self.replace_with_buf.deinit(self.allocator);
        self.create_buf.deinit(self.allocator);
        if (self.confirm_ops) |*ops| ops.deinit(self.allocator);
        self.free_preview_lines();
        self.preview_lines.deinit(self.allocator);
        self.free_tree_lines();
        self.tree_lines.deinit(self.allocator);
        self.free_clipboard();
        self.find_buf.deinit(self.allocator);
        self.find_all_paths.deinit(self.allocator);
        self.find_filtered.deinit(self.allocator);
        self.find_arena.deinit();
        self.free_bookmarks();
        self.bookmarks.deinit(self.allocator);
        self.frame_arena.deinit();
        self.dir_state.deinit();
        self.dest_state.deinit();
        self.loop.stop();
        self.vx.exitAltScreen(self.tty.writer()) catch {};
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
        while (!self.should_quit) {
            const event = self.loop.nextEvent();
            try self.update(event);
            self.draw();
            try self.vx.render(self.tty.writer());
        }
    }

    fn update(self: *App, event: Event) !void {
        switch (event) {
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.writer(), ws),
            .key_press => |key| {
                self.message = null;
                switch (self.mode) {
                    .normal => try self.handle_normal(key),
                    .edit => try self.handle_edit(key),
                    .search => try self.handle_search(key),
                    .replace => try self.handle_replace(key),
                    .confirm => try self.handle_confirm(key),
                    .help => self.handle_help(key),
                    .preview => self.handle_preview(key),
                    .create => try self.handle_create(key),
                    .find => try self.handle_find(key),
                    .bookmark => try self.handle_bookmark(key),
                }
            },
        }
    }

    fn draw(self: *App) void {
        _ = self.frame_arena.reset(.retain_capacity);
        const frame_alloc = self.frame_arena.allocator();

        const win = self.vx.window();
        win.clear();

        const ops_slice = if (self.confirm_ops) |ops| ops.items else null;

        const replace_state: ?render.ReplaceState = if (self.mode == .replace) .{
            .find = self.replace_find_buf.items,
            .replace_with = self.replace_with_buf.items,
            .active_field = self.replace_field,
        } else null;

        const preview_state: ?render.PreviewState = if (self.mode == .preview) .{
            .lines = self.preview_lines.items,
            .scroll = self.preview_scroll,
            .title = self.preview_title[0..self.preview_title_len],
            .is_binary = self.preview_is_binary,
            .is_dir = self.preview_is_dir,
            .total_lines = self.preview_total_lines,
        } else null;

        const find_state: ?render.FindState = if (self.mode == .find) .{
            .query = self.find_buf.items,
            .results = &self.find_all_paths,
            .filtered = self.find_filtered.items,
            .cursor = self.find_cursor,
            .scroll = self.find_scroll,
        } else null;

        const bookmark_state: ?render.BookmarkState = if (self.mode == .bookmark) .{
            .bookmarks = self.bookmarks.items,
            .cursor = self.bookmark_cursor,
            .scroll = self.bookmark_scroll,
        } else null;

        const tree_view_state: ?render.TreeViewState = if (self.show_tree) .{
            .lines = self.tree_lines.items,
            .scroll = self.tree_scroll,
            .total_lines = self.tree_total_lines,
        } else null;

        const dest_panel_state: ?render.DestPanelState = if (self.dual_panel) .{
            .dir_state = &self.dest_state,
            .cursor = self.dest_cursor,
            .scroll = self.dest_scroll,
            .active = self.dest_active,
        } else null;

        render.draw(
            frame_alloc,
            win,
            &self.dir_state,
            self.cursor,
            self.scroll_offset,
            self.mode,
            self.search_buf.items,
            self.message,
            ops_slice,
            self.edit_cursor_col,
            replace_state,
            preview_state,
            self.clip_op,
            self.clip_entries.items.len,
            self.create_buf.items,
            find_state,
            bookmark_state,
            tree_view_state,
            dest_panel_state,
        );

        if (self.mode != .edit and self.mode != .replace and self.mode != .create) {
            win.hideCursor();
        }
    }

    // ─── NORMAL MODE ───

    fn handle_normal(self: *App, key: vaxis.Key) !void {
        const count = self.dir_state.entry_count();

        // Tree view scroll handling
        if (self.show_tree) {
            if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                if (self.tree_scroll + 1 < self.tree_total_lines) {
                    self.tree_scroll += 1;
                }
            } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                if (self.tree_scroll > 0) {
                    self.tree_scroll -= 1;
                }
            } else if (key.matches(vaxis.Key.end, .{})) {
                if (self.tree_total_lines > 0) {
                    self.tree_scroll = self.tree_total_lines -| 1;
                }
            } else if (key.matches(vaxis.Key.home, .{})) {
                self.tree_scroll = 0;
            } else if (key.matches(vaxis.Key.escape, .{})) {
                self.show_tree = false;
            }
            return;
        }

        // Dual-panel: Tab to open/toggle, Ctrl+W to close
        if (key.matches(vaxis.Key.tab, .{})) {
            if (!self.dual_panel) {
                // Open destination panel with same directory
                try self.dest_state.scan(self.dir_state.path);
                self.dest_cursor = 0;
                self.dest_scroll = 0;
                self.dual_panel = true;
                self.dest_active = true;
            } else {
                self.dest_active = !self.dest_active;
            }
            return;
        }
        if (key.matches('w', .{ .ctrl = true })) {
            if (self.dual_panel) {
                self.dual_panel = false;
                self.dest_active = false;
            }
            return;
        }

        // When destination panel is active, handle only basic navigation
        if (self.dual_panel and self.dest_active) {
            try self.handle_dest_panel(key);
            return;
        }

        // Navigation
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            self.move_cursor_down(count);
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            self.move_cursor_up();
        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.right, .{})) {
            try self.enter_or_open();
        } else if (key.matches('-', .{}) or key.matches(vaxis.Key.backspace, .{}) or key.matches(vaxis.Key.left, .{})) {
            try self.go_parent();
        } else if (key.matches(vaxis.Key.home, .{}) or key.matches('0', .{})) {
            self.cursor = 0;
            self.scroll_offset = 0;
        } else if (key.matches(vaxis.Key.end, .{}) or key.matches('$', .{})) {
            if (count > 0) {
                self.cursor = count - 1;
                self.adjust_scroll();
            }
        }
        // Search & filter
        else if (key.matches(vaxis.Key.escape, .{})) {
            if (self.dir_state.search_query.items.len > 0) {
                self.search_buf.clearRetainingCapacity();
                self.dir_state.search_query.clearRetainingCapacity();
                try self.dir_state.apply_filter();
                self.clamp_cursor();
            }
        } else if (key.matches('/', .{})) {
            self.mode = .search;
            self.search_buf.clearRetainingCapacity();
        } else if (key.matches('?', .{})) {
            try self.enter_find_mode();
        }
        // Selection & clipboard
        else if (key.matches(' ', .{})) {
            self.toggle_selection();
        } else if (key.matches('a', .{ .ctrl = true })) {
            self.select_all();
        } else if (key.matches('y', .{})) {
            self.clip_to_clipboard(.copy);
        } else if (key.matches('x', .{})) {
            self.clip_to_clipboard(.cut);
        } else if (key.matches('c', .{})) {
            self.copy_location();
        } else if (key.matches('p', .{})) {
            try self.paste();
        }
        // File operations
        else if (key.matches('.', .{})) {
            try self.dir_state.toggle_hidden();
            self.clamp_cursor();
        } else if (key.matches('Y', .{})) {
            try self.duplicate_entry();
        } else if (key.matches('m', .{})) {
            self.toggle_bookmark();
        }
        // Function keys
        else if (key.matches(vaxis.Key.f1, .{})) {
            self.mode = .help;
        } else if (key.matches(vaxis.Key.f2, .{})) {
            try self.enter_edit_mode();
        } else if (key.matches(vaxis.Key.f3, .{})) {
            self.open_preview();
        } else if (key.matches(vaxis.Key.f4, .{})) {
            self.open_shell();
        } else if (key.matches(vaxis.Key.f5, .{})) {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path_copy = path_buf[0..self.dir_state.path.len];
            @memcpy(path_copy, self.dir_state.path);
            try self.dir_state.scan(path_copy);
            self.clamp_cursor();
        } else if (key.matches('r', .{})) {
            try self.enter_replace_mode();
        } else if (key.matches('n', .{})) {
            self.mode = .create;
            self.create_buf.clearRetainingCapacity();
        } else if (key.matches('D', .{})) {
            try self.delete_selected();

        } else if (key.matches('\\', .{})) {
            self.toggle_tree_view();
        } else if (key.matches('b', .{})) {
            self.enter_bookmark_mode();
        }
        // Drag & drop
        else if (key.matches('d', .{ .ctrl = true })) {
            self.open_ripdrag();
        }
        // Quit
        else if (key.matches('q', .{})) {
            self.should_quit = true;
        }
    }

    // ─── EDIT MODE ───

    fn handle_edit(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            var ops = try self.dir_state.collect_edits(self.allocator);
            if (ops.items.len > 0) {
                self.confirm_ops = ops;
                self.mode = .confirm;
            } else {
                ops.deinit(self.allocator);
                self.mode = .normal;
            }
            return;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            try self.show_confirm();
            return;
        }

        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{ .ctrl = true })) {
            self.move_cursor_down(self.dir_state.entry_count());
            self.sync_edit_cursor();
            return;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{ .ctrl = true })) {
            self.move_cursor_up();
            self.sync_edit_cursor();
            return;
        }

        // Text editing
        const edit_name = self.dir_state.get_edit_name_mut(self.cursor) orelse return;

        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.edit_cursor_col > 0) {
                _ = edit_name.orderedRemove(self.edit_cursor_col - 1);
                self.edit_cursor_col -= 1;
            }
        } else if (key.matches(vaxis.Key.delete, .{})) {
            if (self.edit_cursor_col < edit_name.items.len) {
                _ = edit_name.orderedRemove(self.edit_cursor_col);
            }
        } else if (key.matches(vaxis.Key.left, .{})) {
            if (self.edit_cursor_col > 0) self.edit_cursor_col -= 1;
        } else if (key.matches(vaxis.Key.right, .{})) {
            if (self.edit_cursor_col < edit_name.items.len) self.edit_cursor_col += 1;
        } else if (key.matches(vaxis.Key.home, .{})) {
            self.edit_cursor_col = 0;
        } else if (key.matches(vaxis.Key.end, .{})) {
            self.edit_cursor_col = edit_name.items.len;
        } else if (key.text) |text| {
            for (text) |c| {
                if (c >= 32 and c < 127) {
                    edit_name.insert(self.allocator, self.edit_cursor_col, c) catch break;
                    self.edit_cursor_col += 1;
                }
            }
        } else if (key.codepoint >= 32 and key.codepoint < 127) {
            const c: u8 = @intCast(key.codepoint);
            edit_name.insert(self.allocator, self.edit_cursor_col, c) catch return;
            self.edit_cursor_col += 1;
        }
    }

    // ─── REPLACE MODE ───

    fn handle_replace(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.mode = .normal;
            return;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            try self.show_confirm();
            return;
        }

        if (key.matches(vaxis.Key.tab, .{})) {
            self.replace_field = switch (self.replace_field) {
                .find => .replace_with,
                .replace_with => .find,
            };
            return;
        }

        const buf = switch (self.replace_field) {
            .find => &self.replace_find_buf,
            .replace_with => &self.replace_with_buf,
        };

        if (key.matches(vaxis.Key.backspace, .{})) {
            if (buf.items.len > 0) {
                _ = buf.pop();
            }
        } else if (key.text) |text| {
            try buf.appendSlice(self.allocator, text);
        } else if (key.codepoint >= 32 and key.codepoint < 127) {
            try buf.append(self.allocator, @intCast(key.codepoint));
        } else {
            return;
        }

        // Recompute edit names with current find/replace
        try self.dir_state.apply_search_replace(
            self.replace_find_buf.items,
            self.replace_with_buf.items,
        );
    }

    // ─── SEARCH MODE ───

    fn handle_search(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.mode = .normal;
            self.search_buf.clearRetainingCapacity();
            self.dir_state.search_query.clearRetainingCapacity();
            try self.dir_state.apply_filter();
            self.clamp_cursor();
            return;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            // Guarda o nome do item selecionado antes de limpar o filtro
            const selected_name = if (self.dir_state.get_entry(self.cursor)) |e| e.name else null;

            self.mode = .normal;
            self.search_buf.clearRetainingCapacity();
            self.dir_state.search_query.clearRetainingCapacity();
            try self.dir_state.apply_filter();

            // Posiciona o cursor no item que estava selecionado
            if (selected_name) |name| {
                for (0..self.dir_state.entry_count()) |i| {
                    if (self.dir_state.get_entry(i)) |e| {
                        if (std.mem.eql(u8, e.name, name)) {
                            self.cursor = i;
                            self.adjust_scroll();
                            break;
                        }
                    }
                }
            } else {
                self.cursor = 0;
                self.scroll_offset = 0;
            }
            return;
        }

        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.search_buf.items.len > 0) {
                _ = self.search_buf.pop();
            }
        } else if (key.text) |text| {
            try self.search_buf.appendSlice(self.allocator, text);
        } else if (key.codepoint >= 32 and key.codepoint < 127) {
            try self.search_buf.append(self.allocator, @intCast(key.codepoint));
        } else {
            return;
        }

        self.dir_state.search_query.clearRetainingCapacity();
        try self.dir_state.search_query.appendSlice(self.allocator, self.search_buf.items);
        try self.dir_state.apply_filter();
        self.cursor = 0;
        self.scroll_offset = 0;
    }

    // ─── CREATE MODE ───

    fn handle_create(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.mode = .normal;
            self.create_buf.clearRetainingCapacity();
            return;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.create_buf.items.len == 0) {
                self.mode = .normal;
                return;
            }

            const name = self.create_buf.items;
            const is_dir = name[name.len - 1] == '/';
            const actual_name = if (is_dir) name[0 .. name.len - 1] else name;

            if (actual_name.len == 0) {
                self.mode = .normal;
                self.create_buf.clearRetainingCapacity();
                return;
            }

            var dir = std.fs.openDirAbsolute(self.dir_state.path, .{}) catch |err| {
                const msg = std.fmt.bufPrint(&self.message_buf, "Error: {s}", .{@errorName(err)}) catch "Error";
                self.message = msg;
                self.mode = .normal;
                return;
            };
            defer dir.close();

            if (is_dir) {
                dir.makeDir(actual_name) catch |err| {
                    const msg = std.fmt.bufPrint(&self.message_buf, "mkdir failed: {s}", .{@errorName(err)}) catch "mkdir failed";
                    self.message = msg;
                    self.mode = .normal;
                    return;
                };
                const msg = std.fmt.bufPrint(&self.message_buf, "Created dir: {s}", .{actual_name}) catch "Created";
                self.message = msg;
            } else {
                const file = dir.createFile(actual_name, .{ .exclusive = true }) catch |err| {
                    const msg = std.fmt.bufPrint(&self.message_buf, "Create failed: {s}", .{@errorName(err)}) catch "Create failed";
                    self.message = msg;
                    self.mode = .normal;
                    return;
                };
                file.close();
                const msg = std.fmt.bufPrint(&self.message_buf, "Created file: {s}", .{actual_name}) catch "Created";
                self.message = msg;
            }

            self.mode = .normal;
            self.create_buf.clearRetainingCapacity();

            const path_copy = try self.allocator.dupe(u8, self.dir_state.path);
            defer self.allocator.free(path_copy);
            self.dir_state.scan(path_copy) catch {};
            self.clamp_cursor();
            return;
        }

        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.create_buf.items.len > 0) {
                _ = self.create_buf.pop();
            }
        } else if (key.text) |text| {
            try self.create_buf.appendSlice(self.allocator, text);
        } else if (key.codepoint >= 32 and key.codepoint < 127) {
            try self.create_buf.append(self.allocator, @intCast(key.codepoint));
        }
    }

    // ─── CONFIRM MODE ───

    fn handle_confirm(self: *App, key: vaxis.Key) !void {
        if (key.matches('y', .{}) or key.matches(vaxis.Key.enter, .{})) {
            const ops = self.confirm_ops orelse {
                self.mode = .normal;
                return;
            };

            var applied: usize = 0;
            var dir = std.fs.openDirAbsolute(self.dir_state.path, .{}) catch |err| {
                const msg = std.fmt.bufPrint(&self.message_buf, "Error: {s}", .{@errorName(err)}) catch "Error";
                self.message = msg;
                self.mode = .normal;
                self.confirm_ops = null;
                return;
            };
            defer dir.close();

            for (ops.items) |op| {
                switch (op) {
                    .rename => |r| {
                        dir.rename(r.from, r.to) catch continue;
                        applied += 1;
                    },
                    .delete => |name| {
                        // Try as file first, then as directory tree
                        dir.deleteFile(name) catch {
                            dir.deleteTree(name) catch |err| {
                                const msg = std.fmt.bufPrint(&self.message_buf, "Delete failed: {s}", .{@errorName(err)}) catch "Delete failed";
                                self.message = msg;
                                continue;
                            };
                            applied += 1;
                            continue;
                        };
                        applied += 1;
                    },
                }
            }

            if (self.confirm_ops) |*o| o.deinit(self.allocator);
            self.confirm_ops = null;

            const path_copy = try self.allocator.dupe(u8, self.dir_state.path);
            defer self.allocator.free(path_copy);
            self.dir_state.scan(path_copy) catch {};

            const msg = std.fmt.bufPrint(&self.message_buf, "{d} operation(s) applied", .{applied}) catch "Done";
            self.message = msg;
            self.mode = .normal;
            self.clamp_cursor();
        } else if (key.matches('n', .{}) or key.matches(vaxis.Key.escape, .{})) {
            self.mode = .normal;
            if (self.confirm_ops) |*ops| ops.deinit(self.allocator);
            self.confirm_ops = null;
            self.message = "Cancelled";
        }
    }

    // ─── HELP MODE ───

    fn handle_help(self: *App, key: vaxis.Key) void {
        _ = key;
        self.mode = .normal;
    }

    // ─── PREVIEW MODE ───

    fn handle_preview(self: *App, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{}) or key.matches('l', .{ .ctrl = true })) {
            self.mode = .normal;
        } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.preview_scroll + 1 < self.preview_total_lines) {
                self.preview_scroll += 1;
            }
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.preview_scroll > 0) {
                self.preview_scroll -= 1;
            }
        } else if (key.matches('G', .{})) {
            if (self.preview_total_lines > 0) {
                self.preview_scroll = self.preview_total_lines -| 1;
            }
        } else if (key.matches('g', .{})) {
            self.preview_scroll = 0;
        }
    }

    // ─── FIND MODE (recursive search) ───

    fn enter_find_mode(self: *App) !void {
        self.find_buf.clearRetainingCapacity();
        self.find_all_paths.clearRetainingCapacity();
        self.find_filtered.clearRetainingCapacity();
        _ = self.find_arena.reset(.retain_capacity);

        // Salva estado atual para restaurar no Escape (copia path no find_arena)
        const arena_alloc = self.find_arena.allocator();
        self.find_saved_path = try arena_alloc.dupe(u8, self.dir_state.path);
        self.find_saved_cursor = self.cursor;
        self.find_saved_scroll = self.scroll_offset;
        self.find_cursor = 0;
        self.find_scroll = 0;

        // Walk the current directory recursively
        self.find_all_paths = try dir_mod.recursive_walk(
            self.allocator,
            &self.find_arena,
            self.dir_state.path,
            self.dir_state.show_hidden,
            10000,
        );

        // Initially all results are visible
        for (0..self.find_all_paths.items.len) |i| {
            try self.find_filtered.append(self.allocator, i);
        }

        self.mode = .find;
    }

    fn handle_find(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            // Restaura estado anterior ao find
            if (self.find_saved_path) |saved_path| {
                if (!std.mem.eql(u8, saved_path, self.dir_state.path)) {
                    try self.dir_state.scan(saved_path);
                }
                self.cursor = self.find_saved_cursor;
                self.scroll_offset = self.find_saved_scroll;
                self.find_saved_path = null;
            }
            self.mode = .normal;
            return;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            try self.find_navigate();
            return;
        }

        if (key.matches(vaxis.Key.down, .{})) {
            if (self.find_filtered.items.len > 0 and self.find_cursor + 1 < self.find_filtered.items.len) {
                self.find_cursor += 1;
                self.adjust_find_scroll();
            }
            return;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            if (self.find_cursor > 0) {
                self.find_cursor -= 1;
                self.adjust_find_scroll();
            }
            return;
        }
        if (key.matches(vaxis.Key.end, .{})) {
            if (self.find_filtered.items.len > 0) {
                self.find_cursor = self.find_filtered.items.len - 1;
                self.adjust_find_scroll();
            }
            return;
        }
        if (key.matches(vaxis.Key.home, .{})) {
            self.find_cursor = 0;
            self.find_scroll = 0;
            return;
        }

        // Text input
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.find_buf.items.len > 0) {
                _ = self.find_buf.pop();
            }
        } else if (key.text) |text| {
            try self.find_buf.appendSlice(self.allocator, text);
        } else if (key.codepoint >= 32 and key.codepoint < 127) {
            try self.find_buf.append(self.allocator, @intCast(key.codepoint));
        } else {
            return;
        }

        // Re-filter
        self.find_filtered.clearRetainingCapacity();
        if (self.find_buf.items.len == 0) {
            for (0..self.find_all_paths.items.len) |i| {
                try self.find_filtered.append(self.allocator, i);
            }
        } else {
            for (self.find_all_paths.items, 0..) |path, i| {
                if (dir_mod.fuzzy_match_pub(path, self.find_buf.items)) {
                    try self.find_filtered.append(self.allocator, i);
                }
            }
        }
        self.find_cursor = 0;
        self.find_scroll = 0;
    }

    fn adjust_find_scroll(self: *App) void {
        const win = self.vx.window();
        const visible = if (win.height > 6) win.height - 6 else 1;
        if (self.find_cursor < self.find_scroll) {
            self.find_scroll = self.find_cursor;
        } else if (self.find_cursor >= self.find_scroll + visible) {
            self.find_scroll = self.find_cursor - visible + 1;
        }
    }

    fn find_navigate(self: *App) !void {
        if (self.find_filtered.items.len == 0) {
            self.mode = .normal;
            return;
        }

        const idx = self.find_filtered.items[self.find_cursor];
        const rel_path = self.find_all_paths.items[idx];

        // Build full path
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dir_state.path, rel_path }) catch {
            self.mode = .normal;
            return;
        };

        // Get the directory containing the target
        const dir_path = std.fs.path.dirname(full_path) orelse {
            self.mode = .normal;
            return;
        };

        const basename = std.fs.path.basename(full_path);

        // Navigate to the directory
        try self.dir_state.scan(dir_path);
        self.cursor = 0;
        self.scroll_offset = 0;

        // Try to position cursor on the target file
        for (self.dir_state.filtered_entries.items, 0..) |real_idx, i| {
            const e = self.dir_state.all_entries.items[real_idx];
            if (std.mem.eql(u8, e.name, basename)) {
                self.cursor = i;
                self.adjust_scroll();
                break;
            }
        }

        self.mode = .normal;
    }

    fn open_preview(self: *App) void {
        const entry = self.dir_state.get_entry(self.cursor) orelse return;

        // Set title
        const title_len = @min(entry.name.len, self.preview_title.len);
        @memcpy(self.preview_title[0..title_len], entry.name[0..title_len]);
        self.preview_title_len = title_len;
        self.preview_scroll = 0;
        self.preview_is_binary = false;
        self.preview_is_dir = entry.kind == .dir;

        self.free_preview_lines();

        if (entry.kind == .dir) {
            self.load_dir_preview(entry.name);
        } else {
            self.load_file_preview(entry.name);
        }

        self.mode = .preview;
    }

    fn load_file_preview(self: *App, name: []const u8) void {
        // Check extension first for known binary formats
        if (is_binary_extension(name)) {
            self.preview_is_binary = true;
            self.preview_total_lines = 0;
            return;
        }

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dir_state.path, name }) catch return;

        const file = std.fs.openFileAbsolute(full_path, .{}) catch return;
        defer file.close();

        const max_bytes: usize = 64 * 1024; // read up to 64KB
        const buf = self.allocator.alloc(u8, max_bytes) catch return;
        defer self.allocator.free(buf);

        const n = file.readAll(buf) catch return;
        if (n == 0) {
            self.preview_total_lines = 0;
            return;
        }
        const content = buf[0..n];

        // Check for binary content by scanning for non-text bytes
        if (is_binary_content(content)) {
            self.preview_is_binary = true;
            self.preview_total_lines = 0;
            return;
        }

        self.parse_preview_content(content);
    }

    fn is_binary_extension(name: []const u8) bool {
        const binary_exts = [_][]const u8{
            // Documents
            ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".ods", ".odp",
            // Images
            ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".svg", ".tif", ".tiff", ".psd", ".raw", ".heic", ".avif",
            // Audio/Video
            ".mp3", ".mp4", ".avi", ".mkv", ".mov", ".flac", ".wav", ".ogg", ".webm", ".m4a", ".aac", ".wma", ".wmv",
            // Archives
            ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar", ".zst", ".lz4",
            // Binaries
            ".exe", ".dll", ".so", ".dylib", ".o", ".a", ".lib", ".bin", ".dat",
            // Fonts
            ".ttf", ".otf", ".woff", ".woff2",
            // Other
            ".class", ".pyc", ".wasm", ".sqlite", ".db",
        };
        const dot_pos = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
        const ext = name[dot_pos..];
        for (binary_exts) |bin_ext| {
            if (ascii_eql(ext, bin_ext)) return true;
        }
        return false;
    }

    fn ascii_eql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ac, bc| {
            if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
        }
        return true;
    }

    fn is_binary_content(content: []const u8) bool {
        // Check for common binary magic bytes
        if (content.len >= 4) {
            // PDF: %PDF
            if (std.mem.startsWith(u8, content, "%PDF")) return true;
            // PNG: 0x89 P N G
            if (content[0] == 0x89 and std.mem.startsWith(u8, content[1..], "PNG")) return true;
            // GIF: GIF8
            if (std.mem.startsWith(u8, content, "GIF8")) return true;
            // ZIP/DOCX/XLSX/JAR: PK\x03\x04
            if (content[0] == 'P' and content[1] == 'K' and content[2] == 0x03 and content[3] == 0x04) return true;
            // ELF: \x7fELF
            if (content[0] == 0x7f and std.mem.startsWith(u8, content[1..], "ELF")) return true;
        }
        if (content.len >= 2) {
            // JPEG: 0xFF 0xD8
            if (content[0] == 0xFF and content[1] == 0xD8) return true;
            // Gzip: 0x1F 0x8B
            if (content[0] == 0x1F and content[1] == 0x8B) return true;
        }

        // Scan for null bytes and high ratio of non-printable chars
        const check_len = @min(content.len, 1024);
        var non_text: usize = 0;
        for (content[0..check_len]) |c| {
            if (c == 0) return true;
            if (c < 7 or (c > 14 and c < 32 and c != 27)) non_text += 1;
        }
        // If more than 10% non-text bytes, consider binary
        return non_text * 10 > check_len;
    }

    fn parse_preview_content(self: *App, content: []const u8) void {
        const max_lines: usize = 1000;
        var line_count: usize = 0;
        var start: usize = 0;

        for (content, 0..) |c, i| {
            if (c == '\n') {
                if (line_count < max_lines) {
                    const line = self.allocator.dupe(u8, content[start..i]) catch break;
                    self.preview_lines.append(self.allocator, line) catch {
                        self.allocator.free(line);
                        break;
                    };
                }
                line_count += 1;
                start = i + 1;
            }
        }
        // Last line without trailing newline
        if (start < content.len and line_count < max_lines) {
            const line = self.allocator.dupe(u8, content[start..]) catch {
                self.preview_total_lines = line_count;
                return;
            };
            self.preview_lines.append(self.allocator, line) catch {
                self.allocator.free(line);
                self.preview_total_lines = line_count;
                return;
            };
            line_count += 1;
        }
        self.preview_total_lines = line_count;
    }

    fn load_dir_preview(self: *App, name: []const u8) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dir_state.path, name }) catch return;

        var count: usize = 0;
        self.tree_recurse_into(&self.preview_lines, full_path, "", &count, 0, 200, 3);
        self.preview_total_lines = count;
    }

    fn tree_recurse_into(
        self: *App,
        target: *std.ArrayList([]const u8),
        path: []const u8,
        prefix: []const u8,
        count: *usize,
        depth: usize,
        max_lines: usize,
        max_depth: usize,
    ) void {
        if (count.* >= max_lines or depth > max_depth) return;

        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
        defer dir.close();

        // Collect and sort entries
        var entries = std.ArrayList(std.fs.Dir.Entry).initCapacity(self.allocator, 64) catch return;
        defer entries.deinit(self.allocator);

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            // Skip hidden files
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            const name_copy = self.allocator.dupe(u8, entry.name) catch continue;
            entries.append(self.allocator, .{ .name = name_copy, .kind = entry.kind }) catch {
                self.allocator.free(name_copy);
                break;
            };
        }
        // Sort alphabetically, dirs first
        std.mem.sortUnstable(std.fs.Dir.Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: std.fs.Dir.Entry, b: std.fs.Dir.Entry) bool {
                const a_is_dir = a.kind == .directory;
                const b_is_dir = b.kind == .directory;
                if (a_is_dir != b_is_dir) return a_is_dir;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        defer for (entries.items) |e| self.allocator.free(e.name);

        for (entries.items, 0..) |entry, i| {
            if (count.* >= max_lines) break;
            const is_last = (i == entries.items.len - 1);
            const connector: []const u8 = if (is_last) "└── " else "├── ";
            const icon: []const u8 = switch (entry.kind) {
                .directory => style.icon_dir,
                .sym_link => style.icon_symlink,
                else => style.icon_file,
            };

            const line = std.fmt.allocPrint(self.allocator, "{s}{s}{s}{s}", .{ prefix, connector, icon, entry.name }) catch continue;
            target.append(self.allocator, line) catch {
                self.allocator.free(line);
                break;
            };
            count.* += 1;

            if (entry.kind == .directory and depth < max_depth) {
                var sub_buf: [std.fs.max_path_bytes]u8 = undefined;
                const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ path, entry.name }) catch continue;
                const child_prefix = if (is_last)
                    std.fmt.allocPrint(self.allocator, "{s}    ", .{prefix}) catch continue
                else
                    std.fmt.allocPrint(self.allocator, "{s}│   ", .{prefix}) catch continue;
                defer self.allocator.free(child_prefix);
                self.tree_recurse_into(target, sub_path, child_prefix, count, depth + 1, max_lines, max_depth);
            }
        }
    }

    // ─── TREE VIEW ───

    fn free_tree_lines(self: *App) void {
        for (self.tree_lines.items) |line| {
            self.allocator.free(line);
        }
        self.tree_lines.clearRetainingCapacity();
    }

    fn toggle_tree_view(self: *App) void {
        if (self.show_tree) {
            self.show_tree = false;
            self.free_tree_lines();
            return;
        }
        self.load_tree();
        self.show_tree = true;
    }

    fn load_tree(self: *App) void {
        self.free_tree_lines();
        self.tree_scroll = 0;

        // Add root directory header
        const root_line = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ style.icon_dir, self.dir_state.path }) catch return;
        self.tree_lines.append(self.allocator, root_line) catch {
            self.allocator.free(root_line);
            return;
        };

        var count: usize = 0;
        self.tree_recurse_into(&self.tree_lines, self.dir_state.path, "", &count, 0, 500, 5);
        self.tree_total_lines = self.tree_lines.items.len;
    }

    // ─── CLIPBOARD ───

    fn free_clipboard(self: *App) void {
        for (self.clip_entries.items) |path| {
            self.allocator.free(path);
        }
        self.clip_entries.deinit(self.allocator);
        self.clip_op = .none;
    }

    fn clear_clipboard(self: *App) void {
        for (self.clip_entries.items) |path| {
            self.allocator.free(path);
        }
        self.clip_entries.clearRetainingCapacity();
        self.clip_op = .none;
    }

    fn clip_to_clipboard(self: *App, op: mode_mod.ClipOp) void {
        self.clear_clipboard();
        self.clip_op = op;

        const has_sel = self.dir_state.has_selection();

        if (has_sel) {
            var count: usize = 0;
            for (self.dir_state.filtered_entries.items) |real_idx| {
                const e = self.dir_state.all_entries.items[real_idx];
                if (!e.selected) continue;
                const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_state.path, e.name }) catch continue;
                self.clip_entries.append(self.allocator, full) catch {
                    self.allocator.free(full);
                    continue;
                };
                count += 1;
            }
            const verb: []const u8 = if (op == .cut) "Cut" else "Copied";
            const msg = std.fmt.bufPrint(&self.message_buf, "{s} {d} file(s)", .{ verb, count }) catch return;
            self.message = msg;
            // Clear selection
            for (self.dir_state.all_entries.items) |*e| e.selected = false;
        } else {
            const e = self.dir_state.get_entry(self.cursor) orelse return;
            const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_state.path, e.name }) catch return;
            self.clip_entries.append(self.allocator, full) catch {
                self.allocator.free(full);
                return;
            };
            const verb: []const u8 = if (op == .cut) "Cut" else "Copied";
            const msg = std.fmt.bufPrint(&self.message_buf, "{s}: {s}", .{ verb, e.name }) catch return;
            self.message = msg;
        }
    }

    fn copy_location(self: *App) void {
        const entry = self.dir_state.get_entry(self.cursor) orelse return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dir_state.path, entry.name }) catch return;

        if (self.try_clipboard_cmd(&.{"wl-copy"}, full_path) or
            self.try_clipboard_cmd(&.{ "xclip", "-selection", "clipboard" }, full_path))
        {
            const msg = std.fmt.bufPrint(&self.message_buf, "Path copied: {s}", .{entry.name}) catch return;
            self.message = msg;
        } else {
            self.message = "No clipboard tool found (wl-copy/xclip)";
        }
    }

    fn try_clipboard_cmd(self: *App, argv: []const []const u8, content: []const u8) bool {
        _ = self;
        var child = std.process.Child.init(argv, std.heap.page_allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        _ = child.spawn() catch return false;

        if (child.stdin) |stdin| {
            _ = stdin.write(content) catch {};
            stdin.close();
            child.stdin = null;
        }
        _ = child.wait() catch return false;
        return true;
    }

    fn paste(self: *App) !void {
        if (self.clip_op == .none or self.clip_entries.items.len == 0) {
            self.message = "Clipboard empty";
            return;
        }

        var ok: usize = 0;
        var skipped: usize = 0;

        for (self.clip_entries.items) |src_path| {
            const basename = std.fs.path.basename(src_path);
            const src_stat = std.fs.cwd().statFile(src_path) catch {
                skipped += 1;
                continue;
            };
            var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
            const paste_dir = if (self.dual_panel) self.dest_state.path else self.dir_state.path;
            const dst_path = resolve_available_path(paste_dir, basename, src_stat.kind == .directory, &dst_buf) orelse {
                skipped += 1;
                continue;
            };

            // Check if source and destination are the same
            if (std.mem.eql(u8, src_path, dst_path)) {
                skipped += 1;
                continue;
            }

            if (self.clip_op == .cut) {
                // Try rename first (fast, same filesystem)
                self.rename_path(src_path, dst_path) catch {
                    // Cross-device: copy then delete
                    self.copy_path(src_path, dst_path) catch {
                        skipped += 1;
                        continue;
                    };
                    self.delete_path(src_path) catch {};
                };
                ok += 1;
            } else {
                self.copy_path(src_path, dst_path) catch {
                    skipped += 1;
                    continue;
                };
                ok += 1;
            }
        }

        if (self.clip_op == .cut and ok > 0) {
            self.clear_clipboard();
        }

        // Rescan
        const path_copy = try self.allocator.dupe(u8, self.dir_state.path);
        defer self.allocator.free(path_copy);
        try self.dir_state.scan(path_copy);
        self.clamp_cursor();

        if (self.dual_panel) {
            const dest_copy = try self.allocator.dupe(u8, self.dest_state.path);
            defer self.allocator.free(dest_copy);
            try self.dest_state.scan(dest_copy);
            const dest_count = self.dest_state.entry_count();
            if (self.dest_cursor >= dest_count) {
                self.dest_cursor = if (dest_count > 0) dest_count - 1 else 0;
            }
        }

        if (skipped > 0) {
            const msg = std.fmt.bufPrint(&self.message_buf, "Pasted {d}, skipped {d} (already exist)", .{ ok, skipped }) catch "Done";
            self.message = msg;
        } else {
            const msg = std.fmt.bufPrint(&self.message_buf, "Pasted {d} file(s)", .{ok}) catch "Done";
            self.message = msg;
        }
    }

    fn rename_path(self: *App, src: []const u8, dst: []const u8) !void {
        _ = self;
        // Check if dst exists
        std.fs.accessAbsolute(dst, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Good, destination doesn't exist
                return std.fs.renameAbsolute(src, dst);
            },
            else => return err,
        };
        // Destination exists, skip
        return error.PathAlreadyExists;
    }

    fn copy_path(self: *App, src: []const u8, dst: []const u8) !void {
        // Check if dst exists
        std.fs.accessAbsolute(dst, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Check if source is dir or file
                const stat = try std.fs.cwd().statFile(src);
                if (stat.kind == .directory) {
                    try self.copy_dir_recursive(src, dst);
                } else {
                    try std.fs.copyFileAbsolute(src, dst, .{});
                }
                return;
            },
            else => return err,
        };
        return error.PathAlreadyExists;
    }

    fn copy_dir_recursive(self: *App, src_path: []const u8, dst_path: []const u8) !void {
        // Create destination directory
        const dst_z = try self.allocator.dupeZ(u8, dst_path);
        defer self.allocator.free(dst_z);
        try std.fs.makeDirAbsolute(dst_z);

        var src_dir = try std.fs.openDirAbsolute(src_path, .{ .iterate = true });
        defer src_dir.close();

        var iter = src_dir.iterate();
        while (try iter.next()) |entry| {
            var src_buf: [std.fs.max_path_bytes]u8 = undefined;
            const child_src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src_path, entry.name }) catch continue;
            var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
            const child_dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dst_path, entry.name }) catch continue;

            if (entry.kind == .directory) {
                self.copy_dir_recursive(child_src, child_dst) catch continue;
            } else {
                std.fs.copyFileAbsolute(child_src, child_dst, .{}) catch continue;
            }
        }
    }

    fn delete_path(self: *App, path: []const u8) !void {
        _ = self;
        const stat = try std.fs.cwd().statFile(path);
        if (stat.kind == .directory) {
            try std.fs.deleteTreeAbsolute(path);
        } else {
            try std.fs.deleteFileAbsolute(path);
        }
    }

    fn free_preview_lines(self: *App) void {
        for (self.preview_lines.items) |line| {
            self.allocator.free(line);
        }
        self.preview_lines.clearRetainingCapacity();
    }

    fn duplicate_entry(self: *App) !void {
        const entry = self.dir_state.get_entry(self.cursor) orelse return;

        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ self.dir_state.path, entry.name }) catch return;

        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst_path = resolve_available_path(self.dir_state.path, entry.name, entry.kind == .dir, &dst_buf) orelse return;

        self.copy_path(src_path, dst_path) catch {
            self.message = "Failed to duplicate";
            return;
        };

        const path_copy = try self.allocator.dupe(u8, self.dir_state.path);
        defer self.allocator.free(path_copy);
        try self.dir_state.scan(path_copy);
        self.clamp_cursor();

        const msg = std.fmt.bufPrint(&self.message_buf, "Duplicated as {s}", .{std.fs.path.basename(dst_path)}) catch "Duplicated";
        self.message = msg;
    }

    /// Given a directory and a filename, returns a path with suffix -1, -2, ...
    /// if the original already exists. Returns null if no available name found.
    fn resolve_available_path(dir: []const u8, name: []const u8, is_dir: bool, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
        // Try original path first
        const original = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch return null;
        std.fs.accessAbsolute(original, .{}) catch |err| switch (err) {
            error.FileNotFound => return original,
            else => return null,
        };

        // Split name into stem and extension
        var stem: []const u8 = name;
        var ext: []const u8 = "";
        if (!is_dir) {
            if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                if (dot > 0) {
                    stem = name[0..dot];
                    ext = name[dot..];
                }
            }
        }

        // Find available suffix -1, -2, ...
        var suffix: usize = 1;
        return while (suffix < 100) : (suffix += 1) {
            const candidate = std.fmt.bufPrint(buf, "{s}/{s}-{d}{s}", .{ dir, stem, suffix, ext }) catch return null;
            std.fs.accessAbsolute(candidate, .{}) catch |err| switch (err) {
                error.FileNotFound => break candidate,
                else => return null,
            };
        } else null;
    }

    // ─── ACTIONS ───

    fn open_shell(self: *App) void {
        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        const shell_z = self.allocator.dupeZ(u8, shell) catch return;
        defer self.allocator.free(shell_z);

        const dir_z = self.allocator.dupeZ(u8, self.dir_state.path) catch return;
        defer self.allocator.free(dir_z);

        self.loop.stop();
        self.vx.exitAltScreen(self.tty.writer()) catch {};
        self.tty.deinit();
        _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[?25h") catch {};

        var child = std.process.Child.init(&.{shell_z}, self.allocator);
        child.cwd = dir_z;
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        _ = child.spawnAndWait() catch {};

        self.tty = Tty.init(&self.tty_buf) catch return;
        self.vx.enterAltScreen(self.tty.writer()) catch {};
        self.loop.start() catch return;
        self.vx.queueRefresh();
    }

    // ─── DESTINATION PANEL ───

    fn handle_dest_panel(self: *App, key: vaxis.Key) !void {
        const count = self.dest_state.entry_count();

        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (count > 0 and self.dest_cursor + 1 < count) {
                self.dest_cursor += 1;
                self.adjust_dest_scroll();
            }
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.dest_cursor > 0) {
                self.dest_cursor -= 1;
                self.adjust_dest_scroll();
            }
        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.right, .{})) {
            // Enter directory only
            const entry = self.dest_state.get_entry(self.dest_cursor) orelse return;
            if (entry.kind == .dir) {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const new_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dest_state.path, entry.name }) catch return;
                var real_buf: [std.fs.max_path_bytes]u8 = undefined;
                const resolved = std.fs.cwd().realpath(new_path, &real_buf) catch new_path;
                try self.dest_state.scan(resolved);
                self.dest_cursor = 0;
                self.dest_scroll = 0;
            }
        } else if (key.matches('-', .{}) or key.matches(vaxis.Key.backspace, .{}) or key.matches(vaxis.Key.left, .{})) {
            // Go parent
            const path = self.dest_state.path;
            if (std.mem.eql(u8, path, "/")) return;
            const last_sep = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
            var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
            const parent_src = if (last_sep == 0) "/" else path[0..last_sep];
            @memcpy(parent_buf[0..parent_src.len], parent_src);
            const parent = parent_buf[0..parent_src.len];

            const basename = path[last_sep + 1 ..];
            var name_buf: [std.fs.max_path_bytes]u8 = undefined;
            @memcpy(name_buf[0..basename.len], basename);
            const old_name = name_buf[0..basename.len];

            try self.dest_state.scan(parent);
            self.dest_cursor = 0;
            self.dest_scroll = 0;

            for (0..self.dest_state.entry_count()) |i| {
                if (self.dest_state.get_entry(i)) |e| {
                    if (std.mem.eql(u8, e.name, old_name)) {
                        self.dest_cursor = i;
                        self.adjust_dest_scroll();
                        break;
                    }
                }
            }
        } else if (key.matches(vaxis.Key.home, .{}) or key.matches('0', .{})) {
            self.dest_cursor = 0;
            self.dest_scroll = 0;
        } else if (key.matches(vaxis.Key.end, .{}) or key.matches('$', .{})) {
            if (count > 0) {
                self.dest_cursor = count - 1;
                self.adjust_dest_scroll();
            }
        } else if (key.matches('.', .{})) {
            // Toggle hidden files
            self.dest_state.show_hidden = !self.dest_state.show_hidden;
            self.dest_state.apply_filter() catch {};
            self.dest_cursor = 0;
            self.dest_scroll = 0;
        } else if (key.matches('p', .{})) {
            try self.paste();
        } else if (key.matches('q', .{})) {
            self.should_quit = true;
        }
    }

    fn adjust_dest_scroll(self: *App) void {
        const win = self.vx.window();
        const visible_height = if (win.height > 6) win.height - 6 else 1;
        if (self.dest_cursor < self.dest_scroll) {
            self.dest_scroll = self.dest_cursor;
        } else if (self.dest_cursor >= self.dest_scroll + visible_height) {
            self.dest_scroll = self.dest_cursor - visible_height + 1;
        }
    }

    fn enter_or_open(self: *App) !void {
        const entry = self.dir_state.get_entry(self.cursor) orelse return;

        if (entry.kind == .dir) {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const new_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dir_state.path, entry.name }) catch return;

            var real_buf: [std.fs.max_path_bytes]u8 = undefined;
            const resolved = std.fs.cwd().realpath(new_path, &real_buf) catch new_path;

            try self.dir_state.scan(resolved);
            self.cursor = 0;
            self.scroll_offset = 0;
            if (self.show_tree) {
                self.show_tree = false;
                self.free_tree_lines();
            }
        } else {
            var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ self.dir_state.path, entry.name }) catch return;

            const full_path_z = self.allocator.dupeZ(u8, full_path) catch return;
            defer self.allocator.free(full_path_z);

            if (is_binary_extension(entry.name)) {
                // Binary files: open with xdg-open in background (no need to leave alt screen)
                var child = std.process.Child.init(&.{ "xdg-open", full_path_z }, self.allocator);
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;
                _ = child.spawn() catch {
                    self.message = "Failed to open with xdg-open";
                    return;
                };
                const msg = std.fmt.bufPrint(&self.message_buf, "Opened: {s}", .{entry.name}) catch "Opened";
                self.message = msg;
            } else {
                // Text files: open in $EDITOR
                const editor = std.posix.getenv("VISUAL") orelse std.posix.getenv("EDITOR") orelse "xdg-open";
                const editor_z = self.allocator.dupeZ(u8, editor) catch return;
                defer self.allocator.free(editor_z);

                self.loop.stop();
                self.vx.exitAltScreen(self.tty.writer()) catch {};
                self.tty.deinit();
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[?25h") catch {};

                var child = std.process.Child.init(&.{ editor_z, full_path_z }, self.allocator);
                child.stdin_behavior = .Inherit;
                child.stdout_behavior = .Inherit;
                child.stderr_behavior = .Inherit;
                _ = child.spawnAndWait() catch {};

                self.tty = Tty.init(&self.tty_buf) catch return;
                self.vx.enterAltScreen(self.tty.writer()) catch {};
                self.loop.start() catch return;
                self.vx.queueRefresh();

                const path_copy = self.allocator.dupe(u8, self.dir_state.path) catch return;
                defer self.allocator.free(path_copy);
                self.dir_state.scan(path_copy) catch {};
            }
        }
    }

    fn open_ripdrag(self: *App) void {
        // Collect paths: selected files or current entry
        var paths: std.ArrayList([]const u8) = .{};
        defer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }

        const has_sel = self.dir_state.has_selection();
        if (has_sel) {
            for (self.dir_state.filtered_entries.items) |real_idx| {
                const e = self.dir_state.all_entries.items[real_idx];
                if (!e.selected) continue;
                const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_state.path, e.name }) catch continue;
                paths.append(self.allocator, full) catch {
                    self.allocator.free(full);
                    continue;
                };
            }
        } else {
            const e = self.dir_state.get_entry(self.cursor) orelse return;
            const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_state.path, e.name }) catch return;
            paths.append(self.allocator, full) catch {
                self.allocator.free(full);
                return;
            };
        }

        if (paths.items.len == 0) return;

        // Build argv: ripdrag [paths...]
        var argv: std.ArrayList([]const u8) = .{};
        defer argv.deinit(self.allocator);
        argv.append(self.allocator, "ripdrag") catch return;
        for (paths.items) |p| {
            argv.append(self.allocator, p) catch continue;
        }

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        _ = child.spawn() catch {
            self.message = "Failed to launch ripdrag";
            return;
        };

        const count = paths.items.len;
        const msg = std.fmt.bufPrint(&self.message_buf, "ripdrag: {d} file(s)", .{count}) catch "ripdrag launched";
        self.message = msg;
    }

    fn go_parent(self: *App) !void {
        const path = self.dir_state.path;
        if (std.mem.eql(u8, path, "/")) return;

        const last_sep = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;

        // Copy parent and basename to stack buffers BEFORE scan resets the name arena
        var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
        const parent_src = if (last_sep == 0) "/" else path[0..last_sep];
        @memcpy(parent_buf[0..parent_src.len], parent_src);
        const parent = parent_buf[0..parent_src.len];

        const basename = path[last_sep + 1 ..];
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const old_name_len = basename.len;
        @memcpy(name_buf[0..old_name_len], basename);
        const old_name = name_buf[0..old_name_len];

        try self.dir_state.scan(parent);
        self.cursor = 0;
        self.scroll_offset = 0;
        if (self.show_tree) {
            self.show_tree = false;
            self.free_tree_lines();
        }

        if (old_name_len > 0) {
            for (0..self.dir_state.entry_count()) |i| {
                if (self.dir_state.get_entry(i)) |e| {
                    if (std.mem.eql(u8, e.name, old_name)) {
                        self.cursor = i;
                        self.adjust_scroll();
                        break;
                    }
                }
            }
        }
    }

    fn enter_replace_mode(self: *App) !void {
        try self.dir_state.enter_edit_mode();
        self.mode = .replace;
        self.replace_find_buf.clearRetainingCapacity();
        self.replace_with_buf.clearRetainingCapacity();
        self.replace_field = .find;
    }

    fn enter_edit_mode(self: *App) !void {
        try self.dir_state.enter_edit_mode();
        self.mode = .edit;
        self.sync_edit_cursor();
    }

    fn sync_edit_cursor(self: *App) void {
        if (self.dir_state.get_edit_name(self.cursor)) |name| {
            self.edit_cursor_col = name.len;
        } else {
            self.edit_cursor_col = 0;
        }
    }

    fn delete_selected(self: *App) !void {
        var ops: std.ArrayList(dir_mod.DirState.EditOp) = .{};

        if (self.dir_state.has_selection()) {
            for (self.dir_state.filtered_entries.items) |real_idx| {
                const e = self.dir_state.all_entries.items[real_idx];
                if (e.selected) {
                    try ops.append(self.allocator, .{ .delete = e.name });
                }
            }
        } else {
            const e = self.dir_state.get_entry(self.cursor) orelse return;
            try ops.append(self.allocator, .{ .delete = e.name });
        }

        if (ops.items.len == 0) {
            ops.deinit(self.allocator);
            return;
        }

        if (self.confirm_ops) |*old| old.deinit(self.allocator);
        self.confirm_ops = ops;
        self.mode = .confirm;
    }

    fn show_confirm(self: *App) !void {
        var ops = try self.dir_state.collect_edits(self.allocator);
        if (ops.items.len == 0) {
            ops.deinit(self.allocator);
            self.mode = .normal;
            self.message = "No changes";
            return;
        }
        if (self.confirm_ops) |*old| old.deinit(self.allocator);
        self.confirm_ops = ops;
        self.mode = .confirm;
    }

    fn toggle_selection(self: *App) void {
        if (self.dir_state.get_entry_mut(self.cursor)) |e| {
            e.selected = !e.selected;
        }
        self.move_cursor_down(self.dir_state.entry_count());
    }

    fn select_all(self: *App) void {
        const has_sel = self.dir_state.has_selection();
        for (self.dir_state.filtered_entries.items) |real_idx| {
            self.dir_state.all_entries.items[real_idx].selected = !has_sel;
        }
    }

    // ─── CURSOR HELPERS ───

    fn move_cursor_down(self: *App, count: usize) void {
        if (count == 0) return;
        if (self.cursor < count - 1) {
            self.cursor += 1;
            self.adjust_scroll();
        }
    }

    fn move_cursor_up(self: *App) void {
        if (self.cursor > 0) {
            self.cursor -= 1;
            self.adjust_scroll();
        }
    }

    fn adjust_scroll(self: *App) void {
        const win = self.vx.window();
        const visible_height = if (win.height > 6) win.height - 6 else 1;

        if (self.cursor < self.scroll_offset) {
            self.scroll_offset = self.cursor;
        } else if (self.cursor >= self.scroll_offset + visible_height) {
            self.scroll_offset = self.cursor - visible_height + 1;
        }
    }

    fn clamp_cursor(self: *App) void {
        const count = self.dir_state.entry_count();
        if (count == 0) {
            self.cursor = 0;
        } else if (self.cursor >= count) {
            self.cursor = count - 1;
        }
        self.adjust_scroll();
    }

    // ─── BOOKMARK MODE ───

    fn get_bookmarks_path(buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/.config/xpl-f/bookmarks", .{home}) catch null;
    }

    fn load_bookmarks(self: *App) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const bk_path = get_bookmarks_path(&path_buf) orelse return;

        const file = std.fs.openFileAbsolute(bk_path, .{}) catch return;
        defer file.close();

        const max_bytes: usize = 64 * 1024;
        const buf = self.allocator.alloc(u8, max_bytes) catch return;
        defer self.allocator.free(buf);

        const n = file.readAll(buf) catch return;
        if (n == 0) return;
        const content = buf[0..n];

        var start: usize = 0;
        for (content, 0..) |c, i| {
            if (c == '\n') {
                const line = content[start..i];
                if (line.len > 0) {
                    const duped = self.allocator.dupe(u8, line) catch break;
                    self.bookmarks.append(self.allocator, duped) catch {
                        self.allocator.free(duped);
                        break;
                    };
                }
                start = i + 1;
            }
        }
        // Last line without trailing newline
        if (start < content.len) {
            const line = content[start..];
            if (line.len > 0) {
                const duped = self.allocator.dupe(u8, line) catch return;
                self.bookmarks.append(self.allocator, duped) catch {
                    self.allocator.free(duped);
                };
            }
        }
    }

    fn save_bookmarks(self: *App) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const bk_path = get_bookmarks_path(&path_buf) orelse return;

        // Ensure parent directory exists
        const dir_path = std.fs.path.dirname(bk_path) orelse return;
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };

        std.mem.sortUnstable([]const u8, self.bookmarks.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        const file = std.fs.createFileAbsolute(bk_path, .{ .truncate = true }) catch return;
        defer file.close();

        for (self.bookmarks.items) |path| {
            _ = file.write(path) catch return;
            _ = file.write("\n") catch return;
        }
    }

    fn free_bookmarks(self: *App) void {
        for (self.bookmarks.items) |path| {
            self.allocator.free(path);
        }
        self.bookmarks.clearRetainingCapacity();
    }

    fn toggle_bookmark(self: *App) void {
        // Bookmark the selected entry (if it's a directory) or current directory
        const entry = self.dir_state.get_entry(self.cursor);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const bookmark_path = if (entry != null and entry.?.kind == .dir) blk: {
            const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dir_state.path, entry.?.name }) catch {
                break :blk self.dir_state.path;
            };
            break :blk std.fs.cwd().realpath(full, &real_buf) catch full;
        } else self.dir_state.path;

        // Check if already bookmarked
        for (self.bookmarks.items, 0..) |path, i| {
            if (std.mem.eql(u8, path, bookmark_path)) {
                // Remove it
                self.allocator.free(path);
                _ = self.bookmarks.orderedRemove(i);
                self.save_bookmarks();
                const msg = std.fmt.bufPrint(&self.message_buf, "Bookmark removed", .{}) catch "Removed";
                self.message = msg;
                return;
            }
        }

        // Add new bookmark
        const duped = self.allocator.dupe(u8, bookmark_path) catch return;
        self.bookmarks.append(self.allocator, duped) catch {
            self.allocator.free(duped);
            return;
        };
        self.save_bookmarks();
        const msg = std.fmt.bufPrint(&self.message_buf, "Bookmark added", .{}) catch "Added";
        self.message = msg;
    }

    fn enter_bookmark_mode(self: *App) void {
        if (self.bookmarks.items.len == 0) {
            self.message = "No bookmarks (m to add)";
            return;
        }
        self.bookmark_cursor = 0;
        self.bookmark_scroll = 0;
        self.mode = .bookmark;
    }

    fn handle_bookmark(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            self.mode = .normal;
            return;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            try self.navigate_to_bookmark();
            return;
        }

        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.bookmarks.items.len > 0 and self.bookmark_cursor + 1 < self.bookmarks.items.len) {
                self.bookmark_cursor += 1;
                self.adjust_bookmark_scroll();
            }
            return;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.bookmark_cursor > 0) {
                self.bookmark_cursor -= 1;
                self.adjust_bookmark_scroll();
            }
            return;
        }
        if (key.matches('G', .{})) {
            if (self.bookmarks.items.len > 0) {
                self.bookmark_cursor = self.bookmarks.items.len - 1;
                self.adjust_bookmark_scroll();
            }
            return;
        }
        if (key.matches('g', .{})) {
            self.bookmark_cursor = 0;
            self.bookmark_scroll = 0;
            return;
        }
        if (key.matches('d', .{}) or key.matches('x', .{})) {
            self.remove_bookmark();
            return;
        }
    }

    fn navigate_to_bookmark(self: *App) !void {
        if (self.bookmarks.items.len == 0) {
            self.mode = .normal;
            return;
        }

        const path = self.bookmarks.items[self.bookmark_cursor];

        // Check path exists
        std.fs.accessAbsolute(path, .{}) catch {
            const msg = std.fmt.bufPrint(&self.message_buf, "Path not found, removed", .{}) catch "Not found";
            self.message = msg;
            self.remove_bookmark();
            self.mode = .normal;
            return;
        };

        try self.dir_state.scan(path);
        self.cursor = 0;
        self.scroll_offset = 0;
        self.mode = .normal;
    }

    fn remove_bookmark(self: *App) void {
        if (self.bookmarks.items.len == 0) return;

        self.allocator.free(self.bookmarks.items[self.bookmark_cursor]);
        _ = self.bookmarks.orderedRemove(self.bookmark_cursor);
        self.save_bookmarks();

        if (self.bookmarks.items.len == 0) {
            self.mode = .normal;
            self.message = "Last bookmark removed";
            return;
        }
        if (self.bookmark_cursor >= self.bookmarks.items.len) {
            self.bookmark_cursor = self.bookmarks.items.len - 1;
        }
        self.adjust_bookmark_scroll();
    }

    fn adjust_bookmark_scroll(self: *App) void {
        const visible: usize = 20;
        if (self.bookmark_cursor < self.bookmark_scroll) {
            self.bookmark_scroll = self.bookmark_cursor;
        } else if (self.bookmark_cursor >= self.bookmark_scroll + visible) {
            self.bookmark_scroll = self.bookmark_cursor - visible + 1;
        }
    }

    fn run_external(self: *App, cmd: []const u8) void {
        const cmd_z = self.allocator.dupeZ(u8, cmd) catch return;
        defer self.allocator.free(cmd_z);

        self.loop.stop();
        self.vx.exitAltScreen(self.tty.writer()) catch {};
        self.tty.deinit();
        _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[?25h") catch {};

        var child = std.process.Child.init(&.{cmd_z}, self.allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        _ = child.spawnAndWait() catch {
            // command not found — will restore screen below
        };

        self.tty = Tty.init(&self.tty_buf) catch return;
        self.vx.enterAltScreen(self.tty.writer()) catch {};
        self.loop.start() catch return;
        self.vx.queueRefresh();
    }

};
