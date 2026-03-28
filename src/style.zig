const vaxis = @import("vaxis");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;

// --- Directory entries ---
pub const dir_style: Style = .{
    .fg = .{ .rgb = .{ 97, 175, 239 } }, // blue
    .bold = true,
};

pub const file_style: Style = .{
    .fg = .{ .rgb = .{ 192, 202, 245 } }, // soft white
};

pub const symlink_style: Style = .{
    .fg = .{ .rgb = .{ 86, 182, 194 } }, // cyan
    .italic = true,
};

pub const executable_style: Style = .{
    .fg = .{ .rgb = .{ 166, 209, 137 } }, // green
    .bold = true,
};

// --- UI elements ---
pub const selected_style: Style = .{
    .bg = .{ .rgb = .{ 60, 60, 80 } },
};

pub const header_style: Style = .{
    .fg = .{ .rgb = .{ 180, 190, 220 } },
    .bold = true,
    .bg = .{ .rgb = .{ 35, 35, 50 } },
};

pub const status_normal_style: Style = .{
    .fg = .{ .rgb = .{ 30, 30, 46 } },
    .bg = .{ .rgb = .{ 137, 180, 250 } },
    .bold = true,
};

pub const status_edit_style: Style = .{
    .fg = .{ .rgb = .{ 30, 30, 46 } },
    .bg = .{ .rgb = .{ 249, 226, 175 } },
    .bold = true,
};

pub const status_search_style: Style = .{
    .fg = .{ .rgb = .{ 30, 30, 46 } },
    .bg = .{ .rgb = .{ 166, 209, 137 } },
    .bold = true,
};

pub const status_info_style: Style = .{
    .fg = .{ .rgb = .{ 180, 190, 220 } },
    .bg = .{ .rgb = .{ 40, 40, 55 } },
};

pub const border_style: Style = .{
    .fg = .{ .rgb = .{ 88, 91, 112 } },
};

pub const title_style: Style = .{
    .fg = .{ .rgb = .{ 137, 180, 250 } },
    .bold = true,
};

pub const confirm_border_style: Style = .{
    .fg = .{ .rgb = .{ 249, 226, 175 } },
    .bold = true,
};

pub const error_style: Style = .{
    .fg = .{ .rgb = .{ 243, 139, 168 } },
    .bold = true,
};

pub const status_replace_style: Style = .{
    .fg = .{ .rgb = .{ 30, 30, 46 } },
    .bg = .{ .rgb = .{ 203, 166, 247 } }, // mauve/purple
    .bold = true,
};

pub const replace_match_style: Style = .{
    .fg = .{ .rgb = .{ 166, 227, 161 } }, // green
    .bold = true,
};

pub const dim_style: Style = .{
    .fg = .{ .rgb = .{ 108, 112, 134 } },
};

pub const dest_active_border_style: Style = .{
    .fg = .{ .rgb = .{ 166, 227, 161 } }, // green – destination panel active
};

pub const preview_border_style: Style = .{
    .fg = .{ .rgb = .{ 137, 180, 250 } }, // blue
    .bold = true,
};

pub const preview_line_num_style: Style = .{
    .fg = .{ .rgb = .{ 88, 91, 112 } },
};

pub const preview_text_style: Style = .{
    .fg = .{ .rgb = .{ 192, 202, 245 } },
};

// --- Icons ---
pub const icon_dir = "\u{f07b} ";
pub const icon_file = "\u{f15b} ";
pub const icon_symlink = "\u{f481} ";
