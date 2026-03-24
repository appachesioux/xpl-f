const std = @import("std");
const vaxis = @import("vaxis");
const build_options = @import("build_options");
const style = @import("style.zig");
const mode_mod = @import("mode.zig");
const dir_mod = @import("dir.zig");
const entry_mod = @import("entry.zig");
const utils = @import("utils.zig");

const Window = vaxis.Window;

pub const ReplaceState = struct {
    find: []const u8,
    replace_with: []const u8,
    active_field: mode_mod.ReplaceField,
};

pub const FindState = struct {
    query: []const u8,
    results: *const std.ArrayList([]const u8),
    filtered: []const usize,
    cursor: usize,
    scroll: usize,
};

pub const BookmarkState = struct {
    bookmarks: []const []const u8,
    cursor: usize,
    scroll: usize,
};

pub const PreviewState = struct {
    lines: []const []const u8,
    scroll: usize,
    title: []const u8,
    is_binary: bool,
    is_dir: bool,
    total_lines: usize,
};

pub const TreeViewState = struct {
    lines: []const []const u8,
    scroll: usize,
    total_lines: usize,
};

pub const DestPanelState = struct {
    dir_state: *const dir_mod.DirState,
    cursor: usize,
    scroll: usize,
    active: bool, // has focus
};

// Fixed column widths (right-aligned columns); Name takes the rest
const SIZE_W: usize = 10; // "  1.2M  "
const PERM_W: usize = 15; // " 755 rwxr-xr-x "
const DATE_W: usize = 18; // " 2026-03-18 14:30 "

// Vertical layout: blank row, top separator, header, separator, then entries
const TOP_SEPARATOR_ROW: u16 = 0; // row 0 is blank spacing
const HEADER_ROW: u16 = TOP_SEPARATOR_ROW + 1;
const SEPARATOR_ROW: u16 = HEADER_ROW + 1;
const ENTRIES_ROW: u16 = SEPARATOR_ROW + 1;
const ROWS_BEFORE_ENTRIES: usize = ENTRIES_ROW; // rows consumed before entry list

pub fn draw(
    alloc: std.mem.Allocator,
    win: Window,
    dir_state: *const dir_mod.DirState,
    cursor: usize,
    scroll_offset: usize,
    current_mode: mode_mod.Mode,
    search_query: []const u8,
    message: ?[]const u8,
    confirm_ops: ?[]const dir_mod.DirState.EditOp,
    edit_cursor_col: usize,
    replace_state: ?ReplaceState,
    preview_state: ?PreviewState,
    clip_op: mode_mod.ClipOp,
    clip_count: usize,
    create_buf: []const u8,
    find_state: ?FindState,
    bookmark_state: ?BookmarkState,
    tree_view_state: ?TreeViewState,
    dest_panel: ?DestPanelState,
) void {
    const width = win.width;
    const height = win.height;
    if (width < 10 or height < 5) return;

    // Calculate panel width
    const panel_w: usize = if (dest_panel != null) width / 2 else width;

    // Main bordered area (left panel)
    const main = win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = @intCast(panel_w),
        .height = height,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = if (dest_panel != null and dest_panel.?.active) style.dim_style else style.border_style,
        },
    });

    // Title in the top border
    draw_title(alloc, if (dest_panel != null) main else win, dir_state.path, panel_w);

    // Version in the top-right border (only when single panel)
    if (dest_panel == null) {
        draw_version(alloc, win, width);
    }

    // Interior dimensions (inside border)
    const inner_w = if (main.width > 0) main.width else return;
    const inner_h = if (main.height > 0) main.height else return;

    // Status bar takes the last line inside the border
    // Layout: rows 0..ENTRIES_ROW = blank/header/separator, then entries, last row = status
    const list_height = if (inner_h > ROWS_BEFORE_ENTRIES + 1) inner_h - ROWS_BEFORE_ENTRIES - 1 else return;

    const right_cols = SIZE_W + PERM_W + DATE_W;
    const name_w = if (inner_w > right_cols + 10) inner_w - right_cols else 10;

    // Draw top separator (shared by both views)
    draw_top_separator(main, inner_w, name_w);

    if (tree_view_state) |tvs| {
        // Tree view mode: render tree lines instead of normal list
        draw_tree_view(alloc, main, inner_w, inner_h, tvs);
    } else if (current_mode == .find) {
        if (find_state) |fs| {
            draw_find_inline(alloc, main, inner_w, list_height, fs);
        }
    } else {
        // Draw header
        draw_header(main, inner_w, name_w);

        // Draw separator line below header
        draw_header_separator(main, inner_w, name_w);

        // Draw entries
        draw_entries(alloc, main, dir_state, cursor, scroll_offset, list_height, inner_w, name_w, current_mode, edit_cursor_col);
    }

    // Draw status bar
    draw_status(alloc, main, inner_w, inner_h, current_mode, cursor, dir_state, search_query, message, clip_op, clip_count, create_buf, find_state, tree_view_state);

    // Draw confirm popup if in confirm mode
    if (current_mode == .confirm) {
        if (confirm_ops) |ops| {
            draw_confirm(alloc, win, width, height, ops);
        }
    }

    // Draw replace popup
    if (current_mode == .replace) {
        if (replace_state) |rs| {
            draw_replace(alloc, win, width, height, dir_state, rs);
        }
    }

    // Draw help popup
    if (current_mode == .help) {
        draw_help(win, width, height);
    }

    // Draw preview popup
    if (current_mode == .preview) {
        if (preview_state) |ps| {
            draw_preview(alloc, win, width, height, ps);
        }
    }

    // find popup removido — find agora é inline

    // Draw bookmark popup
    if (current_mode == .bookmark) {
        if (bookmark_state) |bs| {
            draw_bookmarks(alloc, win, width, height, bs);
        }
    }

    // Draw destination panel
    if (dest_panel) |dp| {
        draw_dest_panel(alloc, win, dp, panel_w, width, height);
    }
}

fn draw_title(alloc: std.mem.Allocator, win: Window, path: []const u8, width: usize) void {
    // Write title into the top border row
    if (width < 6) return;
    const max_path = width - 4;
    const display_path = if (path.len > max_path) path[path.len - max_path ..] else path;

    const title = std.fmt.allocPrint(alloc, " {s} ", .{display_path}) catch return;

    _ = win.printSegment(.{
        .text = title,
        // .style = style.title_style,
        .style = style.confirm_border_style,
    }, .{
        .row_offset = 0,
        .col_offset = 2,
    });
}

fn draw_version(alloc: std.mem.Allocator, win: Window, width: usize) void {
    if (width < 20) return;
    const label = std.fmt.allocPrint(alloc, " {s} v{s} ", .{ build_options.app_name, build_options.version }) catch return;
    if (label.len + 2 >= width) return;
    const col: usize = width - label.len - 2;

    _ = win.printSegment(.{
        .text = label,
        // .style = style.title_style,
        .style = style.confirm_border_style,
    }, .{
        .row_offset = 0,
        .col_offset = @intCast(col),
    });
}


fn draw_header(win: Window, width: usize, name_w: usize) void {
    // Fill header bg
    for (0..width) |x| {
        win.writeCell(@intCast(x), HEADER_ROW, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style.header_style,
        });
    }

    _ = win.printSegment(.{
        .text = "  Name",
        .style = style.header_style,
    }, .{ .row_offset = HEADER_ROW, .col_offset = 0 });

    const cols = [_]struct { off: usize, label: []const u8 }{
        .{ .off = name_w, .label = " Size" },
        .{ .off = name_w + SIZE_W, .label = " Perms" },
        .{ .off = name_w + SIZE_W + PERM_W, .label = " Modified" },
    };

    for (cols) |col| {
        if (col.off > 0 and col.off <= width) {
            win.writeCell(@intCast(col.off - 1), HEADER_ROW, .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = style.border_style,
            });
        }
        _ = win.printSegment(.{
            .text = col.label,
            .style = style.header_style,
        }, .{ .row_offset = HEADER_ROW, .col_offset = @intCast(col.off) });
    }
}

fn draw_top_separator(win: Window, width: usize, name_w: usize) void {
    for (0..width) |x| {
        const is_cross = x == name_w - 1 or x == name_w + SIZE_W - 1 or x == name_w + SIZE_W + PERM_W - 1;
        const glyph: []const u8 = if (is_cross) "┬" else "─";
        const s = if (is_cross) style.border_style else style.dim_style;
        win.writeCell(@intCast(x), TOP_SEPARATOR_ROW, .{
            .char = .{ .grapheme = glyph, .width = 1 },
            .style = s,
        });
    }
}

fn draw_header_separator(win: Window, width: usize, name_w: usize) void {
    for (0..width) |x| {
        const is_cross = x == name_w - 1 or x == name_w + SIZE_W - 1 or x == name_w + SIZE_W + PERM_W - 1;
        const glyph: []const u8 = if (is_cross) "┼" else "─";
        const s = if (is_cross) style.border_style else style.dim_style;
        win.writeCell(@intCast(x), SEPARATOR_ROW, .{
            .char = .{ .grapheme = glyph, .width = 1 },
            .style = s,
        });
    }
}

fn draw_tree_view(alloc: std.mem.Allocator, win: Window, width: usize, height: usize, tvs: TreeViewState) void {
    // Use full interior height minus status bar and rows before entries
    const content_h = if (height > ROWS_BEFORE_ENTRIES + 1) height - ROWS_BEFORE_ENTRIES - 1 else return;

    // Header row (leaving row 0 blank for spacing)
    for (0..width) |x| {
        win.writeCell(@intCast(x), HEADER_ROW, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style.header_style,
        });
    }
    _ = win.printSegment(.{
        .text = "  Tree View",
        .style = style.header_style,
    }, .{ .row_offset = HEADER_ROW, .col_offset = 0 });

    // Scroll percentage on the right
    if (tvs.total_lines > 0) {
        const pct = if (tvs.total_lines <= 1) 100 else (tvs.scroll * 100) / (tvs.total_lines -| 1);
        const pos_str = std.fmt.allocPrint(alloc, " {d}% ", .{pct}) catch "";
        if (pos_str.len < width) {
            _ = win.printSegment(.{
                .text = pos_str,
                .style = style.header_style,
            }, .{ .row_offset = HEADER_ROW, .col_offset = @intCast(width -| pos_str.len) });
        }
    }

    // Separator
    for (0..width) |x| {
        win.writeCell(@intCast(x), SEPARATOR_ROW, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = style.dim_style,
        });
    }

    // Tree lines
    var row: usize = 0;
    var idx = tvs.scroll;
    while (row < content_h and idx < tvs.lines.len) : ({
        row += 1;
        idx += 1;
    }) {
        const display_row: u16 = @intCast(row + ENTRIES_ROW);
        const line = tvs.lines[idx];

        const display_style = style.file_style;

        _ = win.printSegment(.{
            .text = std.fmt.allocPrint(alloc, "  {s}", .{line}) catch line,
            .style = display_style,
        }, .{ .row_offset = display_row, .col_offset = 0 });
    }
}

fn draw_entries(
    alloc: std.mem.Allocator,
    win: Window,
    dir_state: *const dir_mod.DirState,
    cursor: usize,
    scroll_offset: usize,
    list_height: usize,
    width: usize,
    name_w: usize,
    current_mode: mode_mod.Mode,
    edit_cursor_col: usize,
) void {
    const count = dir_state.entry_count();

    var row: usize = 0;
    var idx = scroll_offset;
    while (row < list_height and idx < count) : ({
        row += 1;
        idx += 1;
    }) {
        const e = dir_state.get_entry(idx) orelse continue;
        const display_row: u16 = @intCast(row + ENTRIES_ROW);
        const is_cursor = idx == cursor;

        // Base style
        var entry_style = e.get_style();
        if (e.selected) {
            entry_style.bg = style.selected_style.bg;
        }
        if (is_cursor) {
            entry_style.reverse = true;
        }

        // Fill row background
        for (0..width) |x| {
            win.writeCell(@intCast(x), display_row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = entry_style,
            });
        }

        // --- Name column (uses child window to clip) ---
        const name_col = win.child(.{
            .x_off = 0,
            .y_off = @intCast(display_row),
            .width = @intCast(name_w),
            .height = 1,
        });

        if (current_mode == .edit or current_mode == .replace) {
            if (dir_state.get_edit_name(idx)) |edit_name| {
                if (edit_name.len == 0) {
                    _ = name_col.printSegment(.{
                        .text = "  [deleted]",
                        .style = style.error_style,
                    }, .{});
                } else {
                    const name_changed = current_mode == .replace and !std.mem.eql(u8, e.name, edit_name);
                    const display_style = if (name_changed) style.replace_match_style else entry_style;
                    const edit_text = std.fmt.allocPrint(alloc, "  {s}", .{edit_name}) catch edit_name;
                    _ = name_col.printSegment(.{
                        .text = edit_text,
                        .style = display_style,
                    }, .{});
                }
            }
            if (current_mode == .edit and is_cursor) {
                const cursor_col: u16 = @intCast(@min(edit_cursor_col + 2, name_w -| 1));
                win.showCursor(cursor_col, display_row);
            }
        } else {
            // Cursor indicator + icon + name as one formatted string
            const disp_buf = alloc.alloc(u8, 512) catch return;
            const display_name = e.display_name(disp_buf);
            const indicator: []const u8 = if (is_cursor) ">" else " ";
            const icon = e.get_icon();
            const full_name = std.fmt.allocPrint(alloc, "{s} {s}{s}", .{ indicator, icon, display_name }) catch display_name;
            _ = name_col.printSegment(.{
                .text = full_name,
                .style = entry_style,
            }, .{});
        }

        // Vertical separator before Size
        if (name_w > 0) {
            win.writeCell(@intCast(name_w - 1), display_row, .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = style.border_style,
            });
        }

        // --- Right-aligned fixed columns: Size, Perms, Date ---
        const size_start = name_w;
        const perm_start = name_w + SIZE_W;
        const date_start = name_w + SIZE_W + PERM_W;

        // Size column
        const size_col = win.child(.{
            .x_off = @intCast(size_start),
            .y_off = @intCast(display_row),
            .width = SIZE_W,
            .height = 1,
        });
        const size_buf = alloc.alloc(u8, 32) catch return;
        const size_str = e.format_size(size_buf);
        _ = size_col.printSegment(.{ .text = " ", .style = entry_style }, .{});
        _ = size_col.printSegment(.{ .text = size_str, .style = entry_style }, .{ .col_offset = 1 });

        // Separator before Perms
        win.writeCell(@intCast(perm_start - 1), display_row, .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = style.border_style,
        });

        // Perms column
        const perm_col = win.child(.{
            .x_off = @intCast(perm_start),
            .y_off = @intCast(display_row),
            .width = PERM_W,
            .height = 1,
        });
        const perm_buf = alloc.alloc(u8, 32) catch return;
        const perm_str = e.format_perms(perm_buf);
        _ = perm_col.printSegment(.{ .text = " ", .style = entry_style }, .{});
        _ = perm_col.printSegment(.{ .text = perm_str, .style = entry_style }, .{ .col_offset = 1 });

        // Separator before Date
        win.writeCell(@intCast(date_start - 1), display_row, .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = style.border_style,
        });

        // Date column
        const date_w = if (width > date_start) width - date_start else 0;
        if (date_w > 0) {
            const date_col = win.child(.{
                .x_off = @intCast(date_start),
                .y_off = @intCast(display_row),
                .width = @intCast(date_w),
                .height = 1,
            });
            const date_buf = alloc.alloc(u8, 32) catch return;
            const date_str = e.format_date(date_buf);
            _ = date_col.printSegment(.{ .text = " ", .style = entry_style }, .{});
            _ = date_col.printSegment(.{ .text = date_str, .style = entry_style }, .{ .col_offset = 1 });
        }
    }
}

fn draw_status(
    alloc: std.mem.Allocator,
    win: Window,
    width: usize,
    height: usize,
    current_mode: mode_mod.Mode,
    cursor: usize,
    dir_state: *const dir_mod.DirState,
    search_query: []const u8,
    message: ?[]const u8,
    clip_op: mode_mod.ClipOp,
    clip_count: usize,
    create_buf: []const u8,
    find_state: ?FindState,
    tree_view_state: ?TreeViewState,
) void {
    const status_row: u16 = @intCast(height -| 1);

    // Fill status bar background
    for (0..width) |x| {
        win.writeCell(@intCast(x), status_row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style.status_info_style,
        });
    }

    // Mode label
    const mode_label: []const u8 = if (tree_view_state != null) " TREE " else switch (current_mode) {
        .normal => " NORMAL ",
        .edit => " EDIT ",
        .search => " SEARCH ",
        .replace => " REPLACE ",
        .confirm => " CONFIRM ",
        .help => " HELP ",
        .preview => " PREVIEW ",
        .create => " CREATE ",
        .find => " FIND ",
        .bookmark => " BOOKMARK ",
    };
    const mode_style = switch (current_mode) {
        .normal, .help => style.status_normal_style,
        .edit => style.status_edit_style,
        .search, .find => style.status_search_style,
        .replace => style.status_replace_style,
        .confirm => style.status_edit_style,
        .preview => style.status_normal_style,
        .create => style.status_search_style,
        .bookmark => style.status_edit_style,
    };

    _ = win.printSegment(.{
        .text = mode_label,
        .style = mode_style,
    }, .{ .row_offset = status_row, .col_offset = 0 });

    const offset: u16 = @intCast(mode_label.len + 1);

    // Position and filename
    const count = dir_state.entry_count();

    if (tree_view_state) |tvs| {
        const info = std.fmt.allocPrint(alloc, "{d} entries", .{tvs.total_lines}) catch return;
        _ = win.printSegment(.{
            .text = info,
            .style = style.status_info_style,
        }, .{ .row_offset = status_row, .col_offset = offset });
    } else if (current_mode == .search) {
        const info = std.fmt.allocPrint(alloc, "/{s}", .{search_query}) catch return;
        _ = win.printSegment(.{
            .text = info,
            .style = style.status_info_style,
        }, .{ .row_offset = status_row, .col_offset = offset });
    } else if (current_mode == .find) {
        if (find_state) |fs| {
            const info = std.fmt.allocPrint(alloc, "?{s}", .{fs.query}) catch return;
            _ = win.printSegment(.{
                .text = info,
                .style = style.status_info_style,
            }, .{ .row_offset = status_row, .col_offset = offset });
        }
    } else if (current_mode == .create) {
        const hint: []const u8 = if (create_buf.len > 0 and create_buf[create_buf.len - 1] == '/') "(dir) " else "(file) ";
        const info = std.fmt.allocPrint(alloc, "New {s}{s}", .{ hint, create_buf }) catch return;
        _ = win.printSegment(.{
            .text = info,
            .style = style.status_info_style,
        }, .{ .row_offset = status_row, .col_offset = offset });
        // Show cursor
        const cursor_col = offset + @as(u16, @intCast(info.len));
        win.showCursor(cursor_col, status_row);
    } else if (message) |msg| {
        _ = win.printSegment(.{
            .text = msg,
            .style = style.status_info_style,
        }, .{ .row_offset = status_row, .col_offset = offset });
    } else if (count > 0) {
        const entry = dir_state.get_entry(cursor);
        const name = if (entry) |e| e.name else "";
        const info = std.fmt.allocPrint(alloc, "{d}/{d}  {s}", .{ cursor + 1, count, name }) catch return;
        _ = win.printSegment(.{
            .text = info,
            .style = style.status_info_style,
        }, .{ .row_offset = status_row, .col_offset = offset });
    } else {
        _ = win.printSegment(.{
            .text = "(empty)",
            .style = style.dim_style,
        }, .{ .row_offset = status_row, .col_offset = offset });
    }

    // Right-aligned indicators
    if (tree_view_state != null) {
        const right_text: []const u8 = " j/k=Scroll  Home/End  F9/q/Esc=Close ";
        const hint_col: u16 = @intCast(width -| right_text.len);
        _ = win.printSegment(.{
            .text = right_text,
            .style = style.status_normal_style,
        }, .{ .row_offset = status_row, .col_offset = hint_col });
    } else if (current_mode == .find) {
        if (find_state) |fs| {
            const right_text = std.fmt.allocPrint(alloc, " {d}/{d} ", .{ fs.filtered.len, fs.results.items.len }) catch return;
            const hint_col: u16 = @intCast(width -| right_text.len);
            _ = win.printSegment(.{
                .text = right_text,
                .style = style.status_normal_style,
            }, .{ .row_offset = status_row, .col_offset = hint_col });
        }
    } else if (current_mode == .normal) {
        var right_text: []const u8 = " F1=Help ";
        if (clip_op != .none and clip_count > 0) {
            const clip_label: []const u8 = if (clip_op == .cut) "cut" else "copy";
            const clip_hint = std.fmt.allocPrint(alloc, " [{s}:{d}] F1=Help ", .{ clip_label, clip_count }) catch " F1=Help ";
            right_text = clip_hint;
        }
        const hint_col: u16 = @intCast(width -| right_text.len);
        _ = win.printSegment(.{
            .text = right_text,
            .style = style.status_normal_style,
        }, .{ .row_offset = status_row, .col_offset = hint_col });
    }
}

fn draw_confirm(alloc: std.mem.Allocator, win: Window, total_w: usize, total_h: usize, ops: []const dir_mod.DirState.EditOp) void {
    const title = "Apply changes? (y/n)";
    const max_op_len = utils.maxOf(dir_mod.DirState.EditOp, ops, struct {
        fn f(op: dir_mod.DirState.EditOp) usize {
            return switch (op) {
                .rename => |r| 12 + r.from.len + r.to.len, // "  rename: " + from + " -> " + to
                .delete => |name| 10 + name.len, // "  delete: " + name
            };
        }
    }.f);
    const max_line_len = @max(title.len, max_op_len);
    const content_w = max_line_len + 4; // +4 for border + padding
    const popup_w: u16 = @intCast(@min(content_w, total_w -| 4));
    const popup_h: u16 = @intCast(@min(ops.len + 4, total_h -| 4));
    if (popup_w < 20 or popup_h < 4) return;

    const x_off: i17 = @intCast((total_w - popup_w) / 2);
    const y_off: i17 = @intCast((total_h - popup_h) / 2);

    const popup = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = popup_w,
        .height = popup_h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = style.confirm_border_style,
        },
    });

    // Clear popup interior
    popup.clear();

    _ = popup.printSegment(.{
        .text = title,
        .style = style.title_style,
    }, .{ .row_offset = 0, .col_offset = 0 });

    var row: u16 = 1;
    for (ops) |op| {
        if (row >= popup_h -| 2) break;
        const line = switch (op) {
            .rename => |r| std.fmt.allocPrint(alloc, "  rename: {s} -> {s}", .{ r.from, r.to }) catch continue,
            .delete => |name| std.fmt.allocPrint(alloc, "  delete: {s}", .{name}) catch continue,
        };
        const op_style: vaxis.Style = switch (op) {
            .rename => style.symlink_style,
            .delete => style.error_style,
        };
        _ = popup.printSegment(.{
            .text = line,
            .style = op_style,
        }, .{ .row_offset = row, .col_offset = 0 });
        row += 1;
    }
}

fn draw_replace(alloc: std.mem.Allocator, win: Window, total_w: usize, total_h: usize, dir_state: *const dir_mod.DirState, rs: ReplaceState) void {
    const popup_w: u16 = @intCast(@min(50, total_w -| 4));
    const popup_h: u16 = 7;
    if (popup_w < 30 or total_h < popup_h + 4) return;

    const x_off: i17 = @intCast((total_w - popup_w) / 2);
    const y_off: i17 = @intCast((total_h - popup_h) / 2);

    const popup = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = popup_w,
        .height = popup_h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = style.confirm_border_style,
        },
    });

    popup.clear();

    _ = popup.printSegment(.{
        .text = "Search & Replace",
        .style = style.title_style,
    }, .{ .row_offset = 0, .col_offset = 0 });

    // Find field
    const find_indicator: []const u8 = if (rs.active_field == .find) "> " else "  ";
    const find_text = std.fmt.allocPrint(alloc, "{s}Find:    {s}", .{ find_indicator, rs.find }) catch return;
    const find_style: vaxis.Style = if (rs.active_field == .find) style.title_style else style.file_style;
    _ = popup.printSegment(.{ .text = find_text, .style = find_style }, .{ .row_offset = 1, .col_offset = 0 });

    // Replace field
    const repl_indicator: []const u8 = if (rs.active_field == .replace_with) "> " else "  ";
    const repl_text = std.fmt.allocPrint(alloc, "{s}Replace: {s}", .{ repl_indicator, rs.replace_with }) catch return;
    const repl_style: vaxis.Style = if (rs.active_field == .replace_with) style.title_style else style.file_style;
    _ = popup.printSegment(.{ .text = repl_text, .style = repl_style }, .{ .row_offset = 2, .col_offset = 0 });

    // Count affected files
    var count: usize = 0;
    for (dir_state.filtered_entries.items, 0..) |real_idx, i| {
        if (i >= dir_state.edit_names.items.len) break;
        const original = dir_state.all_entries.items[real_idx].name;
        const edited = dir_state.edit_names.items[i].items;
        if (!std.mem.eql(u8, original, edited)) count += 1;
    }

    const count_text = std.fmt.allocPrint(alloc, "{d} file(s) will be renamed", .{count}) catch return;
    const count_style: vaxis.Style = if (count > 0) style.symlink_style else style.dim_style;
    _ = popup.printSegment(.{ .text = count_text, .style = count_style }, .{ .row_offset = 3, .col_offset = 2 });

    // Hints
    _ = popup.printSegment(.{
        .text = "Tab=Switch  Enter=Apply  Esc=Cancel",
        .style = style.dim_style,
    }, .{ .row_offset = 4, .col_offset = 2 });

    // Show cursor in active field
    const label_len: u16 = 11; // "> Find:    " or "> Replace: "
    const text_len: u16 = @intCast(if (rs.active_field == .find) rs.find.len else rs.replace_with.len);
    const cursor_row: u16 = @intCast(@as(i17, y_off) + 1 + @as(i17, if (rs.active_field == .replace_with) @as(u16, 2) else @as(u16, 1)));
    const cursor_col: u16 = @intCast(@as(i17, x_off) + 1 + label_len + text_len);
    win.showCursor(cursor_col, cursor_row);
}

fn draw_preview(alloc: std.mem.Allocator, win: Window, total_w: usize, total_h: usize, ps: PreviewState) void {
    // Popup takes ~80% of the screen
    const popup_w: u16 = @intCast(@max(@min(total_w *| 4 / 5, total_w -| 4), 30));
    const popup_h: u16 = @intCast(@max(@min(total_h *| 4 / 5, total_h -| 4), 8));
    if (popup_w < 20 or popup_h < 6) return;

    const x_off: i17 = @intCast((total_w - popup_w) / 2);
    const y_off: i17 = @intCast((total_h - popup_h) / 2);

    const popup = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = popup_w,
        .height = popup_h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = style.preview_border_style,
        },
    });

    popup.clear();

    // Title in top border
    const max_title = popup_w -| 4;
    const disp_title = if (ps.title.len > max_title) ps.title[0..max_title] else ps.title;
    const title_text = std.fmt.allocPrint(alloc, " {s} ", .{disp_title}) catch return;
    _ = win.printSegment(.{
        .text = title_text,
        .style = style.preview_border_style,
    }, .{
        .row_offset = @intCast(@as(u16, @intCast(@as(i17, y_off)))),
        .col_offset = @intCast(@as(u16, @intCast(@as(i17, x_off) + 2))),
    });

    const inner_w = if (popup.width > 0) popup.width else return;
    const inner_h = if (popup.height > 0) popup.height else return;

    // Reserve last row for hints
    const content_h = inner_h -| 1;

    if (ps.is_binary) {
        _ = popup.printSegment(.{
            .text = "  [binary file]",
            .style = style.dim_style,
        }, .{ .row_offset = 1, .col_offset = 0 });
    } else if (ps.lines.len == 0 and !ps.is_dir) {
        _ = popup.printSegment(.{
            .text = "  [empty file]",
            .style = style.dim_style,
        }, .{ .row_offset = 1, .col_offset = 0 });
    } else {
        const line_num_w: usize = 4; // "NNN "

        var row: usize = 0;
        var idx = ps.scroll;
        while (row < content_h and idx < ps.lines.len) : ({
            row += 1;
            idx += 1;
        }) {
            const display_row: u16 = @intCast(row);

            if (!ps.is_dir) {
                // Line number
                const num_str = std.fmt.allocPrint(alloc, "{d:>3} ", .{idx + 1}) catch continue;
                _ = popup.printSegment(.{
                    .text = num_str,
                    .style = style.preview_line_num_style,
                }, .{ .row_offset = display_row, .col_offset = 0 });
            }

            // Line content (truncated to fit)
            const col_start: u16 = if (ps.is_dir) 0 else @intCast(line_num_w);
            const max_content_w = if (inner_w > col_start) inner_w - col_start else 0;
            if (max_content_w == 0) continue;

            const line = ps.lines[idx];
            // Replace tabs with spaces for display
            const display_line = tab_expand(alloc, line, max_content_w) catch line;
            _ = popup.printSegment(.{
                .text = display_line,
                .style = if (ps.is_dir) style.file_style else style.preview_text_style,
            }, .{ .row_offset = display_row, .col_offset = col_start });
        }
    }

    // Hints at the bottom
    const hints = "j/k=Scroll  g/G=Top/Bottom  p/q/Esc=Close";
    const hint_row: u16 = @intCast(inner_h -| 1);
    _ = popup.printSegment(.{
        .text = hints,
        .style = style.dim_style,
    }, .{ .row_offset = hint_row, .col_offset = 1 });

    // Scroll position indicator (right-aligned)
    if (ps.total_lines > 0) {
        const pct = if (ps.total_lines <= 1) 100 else (ps.scroll * 100) / (ps.total_lines -| 1);
        const pos_str = std.fmt.allocPrint(alloc, "{d}% ", .{pct}) catch return;
        const pos_col: u16 = @intCast(inner_w -| pos_str.len);
        _ = popup.printSegment(.{
            .text = pos_str,
            .style = style.dim_style,
        }, .{ .row_offset = hint_row, .col_offset = pos_col });
    }
}

fn draw_dest_panel(alloc: std.mem.Allocator, win: Window, dp: DestPanelState, panel_w: usize, total_w: usize, total_h: usize) void {
    const x_off: u16 = @intCast(panel_w);
    const dest_w: u16 = @intCast(total_w - panel_w);

    const dest = win.child(.{
        .x_off = @intCast(x_off),
        .y_off = 0,
        .width = dest_w,
        .height = @intCast(total_h),
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = if (dp.active) style.border_style else style.dim_style,
        },
    });

    // Title
    draw_title(alloc, dest, dp.dir_state.path, dest_w);

    const inner_w = if (dest.width > 0) dest.width else return;
    const inner_h = if (dest.height > 0) dest.height else return;

    const list_height = if (inner_h > ROWS_BEFORE_ENTRIES + 1) inner_h - ROWS_BEFORE_ENTRIES - 1 else return;

    // Simplified: only show name column
    draw_top_separator(dest, inner_w, inner_w);

    // Header (just "Name")
    _ = dest.printSegment(.{
        .text = "  Name",
        .style = style.header_style,
    }, .{ .row_offset = HEADER_ROW, .col_offset = 0 });

    // Separator
    for (0..inner_w) |x| {
        dest.writeCell(@intCast(x), SEPARATOR_ROW, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = style.dim_style,
        });
    }

    // Entries
    const count = dp.dir_state.entry_count();
    var row: usize = 0;
    var idx = dp.scroll;
    while (row < list_height and idx < count) : ({
        row += 1;
        idx += 1;
    }) {
        const e = dp.dir_state.get_entry(idx) orelse continue;
        const display_row: u16 = @intCast(row + ENTRIES_ROW);
        const is_cursor = idx == dp.cursor;

        var entry_style = e.get_style();
        if (is_cursor) {
            entry_style.reverse = true;
        }

        for (0..inner_w) |x| {
            dest.writeCell(@intCast(x), display_row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = entry_style,
            });
        }

        const disp_buf = alloc.alloc(u8, 512) catch return;
        const display_name = e.display_name(disp_buf);
        const indicator: []const u8 = if (is_cursor) ">" else " ";
        const icon = e.get_icon();
        const full_name = std.fmt.allocPrint(alloc, "{s} {s}{s}", .{ indicator, icon, display_name }) catch display_name;
        _ = dest.printSegment(.{
            .text = full_name,
            .style = entry_style,
        }, .{ .row_offset = display_row, .col_offset = 0 });
    }

    // Status bar
    const status_row: u16 = @intCast(inner_h -| 1);
    for (0..inner_w) |x| {
        dest.writeCell(@intCast(x), status_row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style.status_info_style,
        });
    }
    if (count > 0) {
        const info = std.fmt.allocPrint(alloc, " {d}/{d}", .{ dp.cursor + 1, count }) catch return;
        _ = dest.printSegment(.{
            .text = info,
            .style = style.status_info_style,
        }, .{ .row_offset = status_row, .col_offset = 0 });
    }
}

fn draw_find_inline(alloc: std.mem.Allocator, win: Window, width: usize, list_height: usize, fs: FindState) void {
    var row: usize = 0;
    var idx = fs.scroll;
    while (row < list_height and idx < fs.filtered.len) : ({
        row += 1;
        idx += 1;
    }) {
        const real_idx = fs.filtered[idx];
        const path = fs.results.items[real_idx];
        const display_row: u16 = @intCast(row + ENTRIES_ROW);
        const is_cursor = idx == fs.cursor;

        var entry_style: vaxis.Style = style.file_style;
        if (is_cursor) {
            entry_style.reverse = true;
        }

        // Fill row background
        for (0..width) |x| {
            win.writeCell(@intCast(x), display_row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = entry_style,
            });
        }

        const indicator: []const u8 = if (is_cursor) "> " else "  ";
        const line = std.fmt.allocPrint(alloc, "{s}{s}", .{ indicator, path }) catch continue;
        _ = win.printSegment(.{
            .text = line,
            .style = entry_style,
        }, .{ .row_offset = display_row, .col_offset = 0 });
    }
}

fn draw_find(alloc: std.mem.Allocator, win: Window, total_w: usize, total_h: usize, fs: FindState) void {
    const popup_w: u16 = @intCast(@max(@min(total_w *| 4 / 5, total_w -| 4), 30));
    const popup_h: u16 = @intCast(@max(@min(total_h *| 4 / 5, total_h -| 4), 8));
    if (popup_w < 20 or popup_h < 6) return;

    const x_off: i17 = @intCast((total_w - popup_w) / 2);
    const y_off: i17 = @intCast((total_h - popup_h) / 2);

    const popup = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = popup_w,
        .height = popup_h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = style.confirm_border_style,
        },
    });

    popup.clear();

    const inner_w = if (popup.width > 0) popup.width else return;
    const inner_h = if (popup.height > 0) popup.height else return;

    // Search input line
    const query_text = std.fmt.allocPrint(alloc, " find: {s}", .{fs.query}) catch return;
    _ = popup.printSegment(.{
        .text = query_text,
        .style = style.title_style,
    }, .{ .row_offset = 0, .col_offset = 0 });

    // Show cursor
    const cursor_col: u16 = @intCast(@as(i17, x_off) + 1 + @as(i17, @intCast(query_text.len)));
    const cursor_row: u16 = @intCast(@as(i17, y_off) + 1);
    win.showCursor(cursor_col, cursor_row);

    // Result count
    const count_text = std.fmt.allocPrint(alloc, " {d}/{d}", .{ fs.filtered.len, fs.results.items.len }) catch return;
    const count_col: u16 = @intCast(inner_w -| count_text.len);
    _ = popup.printSegment(.{
        .text = count_text,
        .style = style.dim_style,
    }, .{ .row_offset = 0, .col_offset = count_col });

    // Results list
    const list_h = inner_h -| 2; // reserve row 0 for query, last row for hints
    var row: usize = 0;
    var idx = fs.scroll;
    while (row < list_h and idx < fs.filtered.len) : ({
        row += 1;
        idx += 1;
    }) {
        const real_idx = fs.filtered[idx];
        const path = fs.results.items[real_idx];
        const display_row: u16 = @intCast(row + 1);
        const is_cursor = idx == fs.cursor;

        // Highlight cursor line
        if (is_cursor) {
            for (0..inner_w) |x| {
                popup.writeCell(@intCast(x), display_row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .reverse = true },
                });
            }
        }

        const indicator: []const u8 = if (is_cursor) " > " else "   ";
        const line = std.fmt.allocPrint(alloc, "{s}{s}", .{ indicator, path }) catch continue;
        const entry_style: vaxis.Style = if (is_cursor) .{ .reverse = true } else style.file_style;
        _ = popup.printSegment(.{
            .text = line,
            .style = entry_style,
        }, .{ .row_offset = display_row, .col_offset = 0 });
    }

    // Hints at the bottom
    const hint_row: u16 = @intCast(inner_h -| 1);
    _ = popup.printSegment(.{
        .text = "j/k=Navigate  Enter=Go  Esc=Cancel",
        .style = style.dim_style,
    }, .{ .row_offset = hint_row, .col_offset = 1 });
}

fn draw_bookmarks(alloc: std.mem.Allocator, win: Window, total_w: usize, total_h: usize, bs: BookmarkState) void {
    const max_path_len = utils.maxOf([]const u8, bs.bookmarks, struct {
        fn f(s: []const u8) usize {
            return s.len;
        }
    }.f);
    const popup_w: u16 = @intCast(@max(@min(max_path_len + 9, total_w -| 4), 30)); // +9 for indicator + border + padding + right margin
    const popup_h: u16 = @intCast(@max(@min(bs.bookmarks.len + 4, total_h -| 4), 6));
    if (popup_w < 20 or popup_h < 4) return;

    const x_off: i17 = @intCast((total_w - popup_w) / 2);
    const y_off: i17 = @intCast((total_h - popup_h) / 2);

    const popup = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = popup_w,
        .height = popup_h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = style.confirm_border_style,
        },
    });

    popup.clear();

    const inner_w = if (popup.width > 0) popup.width else return;
    const inner_h = if (popup.height > 0) popup.height else return;

    // Title
    const title_text = std.fmt.allocPrint(alloc, " Bookmarks ({d}) ", .{bs.bookmarks.len}) catch return;
    _ = win.printSegment(.{
        .text = title_text,
        .style = style.confirm_border_style,
    }, .{
        .row_offset = @intCast(@as(u16, @intCast(@as(i17, y_off)))),
        .col_offset = @intCast(@as(u16, @intCast(@as(i17, x_off) + 2))),
    });

    // List
    const list_h = inner_h -| 1; // reserve last row for hints
    var row: usize = 0;
    var idx = bs.scroll;
    while (row < list_h and idx < bs.bookmarks.len) : ({
        row += 1;
        idx += 1;
    }) {
        const path = bs.bookmarks[idx];
        const display_row: u16 = @intCast(row);
        const is_cursor = idx == bs.cursor;

        if (is_cursor) {
            for (0..inner_w) |x| {
                popup.writeCell(@intCast(x), display_row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .reverse = true },
                });
            }
        }

        const indicator: []const u8 = if (is_cursor) " > " else "   ";
        const max_path = inner_w -| 4;
        const display_path = if (path.len > max_path) path[path.len - max_path ..] else path;
        const line = std.fmt.allocPrint(alloc, "{s}{s}", .{ indicator, display_path }) catch continue;
        const entry_style: vaxis.Style = if (is_cursor) .{ .reverse = true } else style.file_style;
        _ = popup.printSegment(.{
            .text = line,
            .style = entry_style,
        }, .{ .row_offset = display_row, .col_offset = 0 });
    }

    // Hints
    const hint_row: u16 = @intCast(inner_h -| 1);
    _ = popup.printSegment(.{
        .text = "j/k=Navigate  Enter=Go  d=Remove  Esc=Close",
        .style = style.dim_style,
    }, .{ .row_offset = hint_row, .col_offset = 1 });
}

fn tab_expand(alloc: std.mem.Allocator, line: []const u8, max_w: usize) ![]const u8 {
    var has_tab = false;
    for (line) |c| {
        if (c == '\t') {
            has_tab = true;
            break;
        }
    }
    if (!has_tab) {
        if (line.len > max_w) return line[0..max_w];
        return line;
    }

    var buf = try std.ArrayList(u8).initCapacity(alloc, @min(line.len * 2, max_w));
    for (line) |c| {
        if (buf.items.len >= max_w) break;
        if (c == '\t') {
            const spaces = 4 - (buf.items.len % 4);
            for (0..spaces) |_| {
                if (buf.items.len >= max_w) break;
                try buf.append(alloc, ' ');
            }
        } else {
            try buf.append(alloc, c);
        }
    }
    return buf.items;
}

fn draw_help(win: Window, total_w: usize, total_h: usize) void {
    const help_lines = [_][]const u8{
        "        INFO",
        "",
        "  F1          Help",
        "  q           Quit",
        "",
        "        NAVIGATION",
        "",
        "  j / ↓       Move down",
        "  k / ↑       Move up",
        "  > / Enter   Open / Enter dir",
        "  < / -       Go to parent",
        "  0 / Home    Go to top",
        "  $ / End     Go to bottom",
        "  Tab         Dual Panel - Copy/Move",
        "  C-w         Close Dual Panel",
        "",
        "        SEARCH & FILTER",
        "",
        "  /           Search",
        "  r           Search & Replace",
        "  ?           Find recursive",
        "  \\           Tree view",
        "",
        "        OPERATIONS",
        "",
        "  Space       Select entry",
        "  C-a         Select all",
        "  C-d         Drag & drop",
        "  n           New file/dir",
        "  Y           Duplicate file",
        "  D           Delete file",
        "  x           Cut",
        "  F2          Rename (edit mode)",
        "  F3          Preview",
        "  F4          Shell here",
        "  F5          Refresh",
        "  c           Copy path",
        "  y           Copy",
        "  p           Paste",
        "  b           Bookmarks",
        "  m           Toggle bookmark",
        "  .           Toggle hidden",
        "",
        "",
        "     Press any key to close",
    };

    const popup_w: u16 = @intCast(@min(38, total_w -| 4));
    const popup_h: u16 = @intCast(@min(help_lines.len + 2, total_h -| 4));
    if (popup_w < 20 or popup_h < 4) return;

    const x_off: i17 = @intCast((total_w - popup_w) / 2);
    const y_off: i17 = @intCast((total_h - popup_h) / 2);

    const popup = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = popup_w,
        .height = popup_h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = style.confirm_border_style,
        },
    });

    popup.clear();

    for (help_lines, 0..) |line, i| {
        if (i >= popup_h -| 2) break;
        const row: u16 = @intCast(i);
        const line_style: vaxis.Style = if (line.len > 0 and line[0] == ' ' and line.len > 1 and line[1] == ' ' and line.len > 2 and line[2] != ' ')
            style.file_style
        else
            style.title_style;
        _ = popup.printSegment(.{
            .text = line,
            .style = line_style,
        }, .{ .row_offset = row, .col_offset = 0 });
    }
}

