const std = @import("std");
const vaxis = @import("vaxis");
const build_options = @import("build_options");
const style = @import("style.zig");
const mode_mod = @import("mode.zig");
const dir_mod = @import("dir.zig");
const entry_mod = @import("entry.zig");

const Window = vaxis.Window;

pub const ReplaceState = struct {
    find: []const u8,
    replace_with: []const u8,
    active_field: mode_mod.ReplaceField,
};

pub const PreviewState = struct {
    lines: []const []const u8,
    scroll: usize,
    title: []const u8,
    is_binary: bool,
    is_dir: bool,
    total_lines: usize,
};

// Column widths as fractions of available width
const NAME_RATIO = 0.55;
const SIZE_RATIO = 0.15;
// DATE takes the rest

pub fn draw(
    alloc: std.mem.Allocator,
    win: Window,
    dir_state: *const dir_mod.DirState,
    cursor: usize,
    scroll_offset: usize,
    current_mode: mode_mod.Mode,
    pending_key: mode_mod.PendingKey,
    search_query: []const u8,
    message: ?[]const u8,
    confirm_ops: ?[]const dir_mod.DirState.EditOp,
    edit_cursor_col: usize,
    replace_state: ?ReplaceState,
    preview_state: ?PreviewState,
    clip_op: mode_mod.ClipOp,
    clip_count: usize,
) void {
    const width = win.width;
    const height = win.height;
    if (width < 10 or height < 5) return;

    // Main bordered area
    const main = win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = width,
        .height = height,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = style.border_style,
        },
    });

    // Title in the top border
    draw_title(alloc, win, dir_state.path, width);

    // Version in the top-right border
    draw_version(alloc, win, width);

    // Interior dimensions (inside border)
    const inner_w = if (main.width > 0) main.width else return;
    const inner_h = if (main.height > 0) main.height else return;

    // Status bar takes the last line inside the border
    // Layout: row 0 = header, row 1 = separator, row 2+ = entries, last row = status
    const list_height = if (inner_h > 3) inner_h - 3 else return;

    const name_w = calc_name_width(inner_w);
    const size_w = calc_size_width(inner_w);

    // Draw header
    draw_header(main, inner_w, name_w, size_w);

    // Draw separator line below header
    draw_header_separator(main, inner_w, name_w, size_w);

    // Draw entries
    draw_entries(alloc, main, dir_state, cursor, scroll_offset, list_height, inner_w, name_w, size_w, current_mode, edit_cursor_col);

    // Draw status bar
    draw_status(alloc, main, inner_w, inner_h, current_mode, pending_key, cursor, dir_state, search_query, message, clip_op, clip_count);

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
}

fn draw_title(alloc: std.mem.Allocator, win: Window, path: []const u8, width: usize) void {
    // Write title into the top border row
    if (width < 6) return;
    const max_path = width - 4;
    const display_path = if (path.len > max_path) path[path.len - max_path ..] else path;

    const title = std.fmt.allocPrint(alloc, " {s} ", .{display_path}) catch return;

    _ = win.printSegment(.{
        .text = title,
        .style = style.title_style,
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
        .style = style.title_style,
    }, .{
        .row_offset = 0,
        .col_offset = @intCast(col),
    });
}

fn draw_header(win: Window, width: usize, name_w: usize, size_w: usize) void {
    // Fill header bg
    for (0..width) |x| {
        win.writeCell(@intCast(x), 0, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style.header_style,
        });
    }

    _ = win.printSegment(.{
        .text = "  Name",
        .style = style.header_style,
    }, .{ .row_offset = 0, .col_offset = 0 });

    // Vertical separator before Size
    if (name_w > 0) {
        win.writeCell(@intCast(name_w - 1), 0, .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = style.border_style,
        });
    }

    _ = win.printSegment(.{
        .text = " Size",
        .style = style.header_style,
    }, .{ .row_offset = 0, .col_offset = @intCast(name_w) });

    // Vertical separator before Modified
    const date_col = name_w + size_w;
    if (date_col > 0) {
        win.writeCell(@intCast(date_col - 1), 0, .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = style.border_style,
        });
    }

    _ = win.printSegment(.{
        .text = " Modified",
        .style = style.header_style,
    }, .{ .row_offset = 0, .col_offset = @intCast(date_col) });
}

fn draw_header_separator(win: Window, width: usize, name_w: usize, size_w: usize) void {
    for (0..width) |x| {
        const glyph: []const u8 = if (x == name_w - 1 or x == name_w + size_w - 1) "┼" else "─";
        const s = if (x == name_w - 1 or x == name_w + size_w - 1) style.border_style else style.dim_style;
        win.writeCell(@intCast(x), 1, .{
            .char = .{ .grapheme = glyph, .width = 1 },
            .style = s,
        });
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
    size_w: usize,
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
        const display_row: u16 = @intCast(row + 2); // +2 for header + separator
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

        // --- Size column (uses child window to clip) ---
        const size_col = win.child(.{
            .x_off = @intCast(name_w),
            .y_off = @intCast(display_row),
            .width = @intCast(size_w),
            .height = 1,
        });
        const size_buf = alloc.alloc(u8, 32) catch return;
        const size_str = e.format_size(size_buf);
        _ = size_col.printSegment(.{
            .text = " ",
            // .style = if (is_cursor) entry_style else style.dim_style,
            .style = entry_style,
        }, .{});
        _ = size_col.printSegment(.{
            .text = size_str,
            // .style = if (is_cursor) entry_style else style.dim_style,
            .style = entry_style,
        }, .{ .col_offset = 1 });

        // Vertical separator before Date
        const date_start = name_w + size_w;
        if (date_start > 0) {
            win.writeCell(@intCast(date_start - 1), display_row, .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = style.border_style,
            });
        }

        // --- Date column (uses child window to clip) ---
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
            _ = date_col.printSegment(.{
                .text = " ",
                // .style = if (is_cursor) entry_style else style.dim_style,
                .style = entry_style,
            }, .{});
            _ = date_col.printSegment(.{
                .text = date_str,
                // .style = if (is_cursor) entry_style else style.dim_style,
                .style = entry_style,
            }, .{ .col_offset = 1 });
        }
    }
}

fn draw_status(
    alloc: std.mem.Allocator,
    win: Window,
    width: usize,
    height: usize,
    current_mode: mode_mod.Mode,
    pending_key: mode_mod.PendingKey,
    cursor: usize,
    dir_state: *const dir_mod.DirState,
    search_query: []const u8,
    message: ?[]const u8,
    clip_op: mode_mod.ClipOp,
    clip_count: usize,
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
    const mode_label = switch (current_mode) {
        .normal => " NORMAL ",
        .edit => " EDIT ",
        .search => " SEARCH ",
        .replace => " REPLACE ",
        .confirm => " CONFIRM ",
        .help => " HELP ",
        .preview => " PREVIEW ",
    };
    const mode_style = switch (current_mode) {
        .normal, .help => style.status_normal_style,
        .edit => style.status_edit_style,
        .search => style.status_search_style,
        .replace => style.status_replace_style,
        .confirm => style.status_edit_style,
        .preview => style.status_normal_style,
    };

    _ = win.printSegment(.{
        .text = mode_label,
        .style = mode_style,
    }, .{ .row_offset = status_row, .col_offset = 0 });

    var offset: u16 = @intCast(mode_label.len + 1);

    // Pending key indicator
    if (pending_key != .none) {
        const pending_str = switch (pending_key) {
            .g => "g",
            .d => "d",
            .y => "y",
            .none => "",
        };
        _ = win.printSegment(.{
            .text = pending_str,
            .style = style.status_info_style,
        }, .{ .row_offset = status_row, .col_offset = offset });
        offset += 2;
    }

    // Position and filename
    const count = dir_state.entry_count();

    if (current_mode == .search) {
        const info = std.fmt.allocPrint(alloc, "/{s}", .{search_query}) catch return;
        _ = win.printSegment(.{
            .text = info,
            .style = style.status_info_style,
        }, .{ .row_offset = status_row, .col_offset = offset });
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
    if (current_mode == .normal) {
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
    const popup_w: u16 = @intCast(@min(60, total_w -| 4));
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
        .text = "Apply changes? (y/n)",
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

fn draw_help(win: Window, total_w: usize, total_h: usize) void {
    const help_lines = [_][]const u8{
        "         NORMAL MODE",
        "",
        "  j / ↓       Move down",
        "  k / ↑       Move up",
        "  l / Enter   Open / Enter dir",
        "  h / -       Go to parent",
        "  g g         Go to top",
        "  G           Go to bottom",
        "  /           Search",
        "  r           Search & Replace",
        "  i           Edit mode",
        "  .           Toggle hidden",
        "  Space       Select entry",
        "  y y         Copy to clipboard",
        "  y l         Copy path to clipboard",
        "  d d         Cut to clipboard",
        "  D           Delete",
        "  p           Paste",
        "  C-l         Preview file",
        "  s           Open shell here",
        "  C-p         Find file (ff)",
        "  C-f         Grep content (gg)",
        "  q           Quit",
        "",
        "         EDIT MODE",
        "",
        "  ↓ / C-j     Move down",
        "  ↑ / C-k     Move up",
        "  Esc         Review changes",
        "  Enter       Review changes",
        "",
        "       REPLACE MODE",
        "",
        "  Tab         Switch field",
        "  Enter       Apply changes",
        "  Esc         Cancel",
        "",
        "         SEARCH MODE",
        "",
        "  Enter       Accept filter",
        "  Esc         Cancel",
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

// --- Layout math ---

fn calc_name_width(total: usize) usize {
    const w: usize = @intFromFloat(@as(f64, @floatFromInt(total)) * NAME_RATIO);
    return @max(w, 10);
}

fn calc_size_width(total: usize) usize {
    const w: usize = @intFromFloat(@as(f64, @floatFromInt(total)) * SIZE_RATIO);
    return @max(w, 6);
}
