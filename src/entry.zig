const std = @import("std");
const vaxis = @import("vaxis");
const style = @import("style.zig");

pub const EntryKind = enum {
    dir,
    file,
    symlink,
    other,
};

pub const FileEntry = struct {
    name: []const u8,
    size: u64,
    modified: i128,
    kind: EntryKind,
    is_executable: bool,
    selected: bool,
    mode: u32,

    pub fn get_style(self: FileEntry) vaxis.Style {
        if (self.selected) {
            return style.selected_style;
        }
        return switch (self.kind) {
            .dir => style.dir_style,
            .symlink => style.symlink_style,
            .file => if (self.is_executable) style.executable_style else style.file_style,
            .other => style.dim_style,
        };
    }

    pub fn get_icon(self: FileEntry) []const u8 {
        return switch (self.kind) {
            .dir => style.icon_dir,
            .symlink => style.icon_symlink,
            .file => style.icon_file,
            .other => style.icon_file,
        };
    }

    pub fn format_size(self: FileEntry, buf: []u8) []const u8 {
        if (self.kind == .dir) {
            return "-";
        }
        const size_f: f64 = @floatFromInt(self.size);
        if (self.size < 1024) {
            return std.fmt.bufPrint(buf, "{d}B", .{self.size}) catch "-";
        } else if (self.size < 1024 * 1024) {
            return std.fmt.bufPrint(buf, "{d:.1}K", .{size_f / 1024.0}) catch "-";
        } else if (self.size < 1024 * 1024 * 1024) {
            return std.fmt.bufPrint(buf, "{d:.1}M", .{size_f / (1024.0 * 1024.0)}) catch "-";
        } else {
            return std.fmt.bufPrint(buf, "{d:.1}G", .{size_f / (1024.0 * 1024.0 * 1024.0)}) catch "-";
        }
    }

    pub fn format_perms(self: FileEntry, buf: []u8) []const u8 {
        const m = self.mode;
        const octal = std.fmt.bufPrint(buf[0..3], "{o:0>3}", .{m & 0o777}) catch return "-";
        _ = octal;
        buf[3] = ' ';
        const rwx = "rwxrwxrwx";
        const bits = [9]u32{ 0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001 };
        for (0..9) |i| {
            buf[4 + i] = if (m & bits[i] != 0) rwx[i] else '-';
        }
        return buf[0..13];
    }

    pub fn format_date(self: FileEntry, buf: []u8) []const u8 {
        if (self.modified == 0) return "-";
        const epoch_secs: i64 = @intCast(@divFloor(self.modified, std.time.ns_per_s));
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, epoch_secs)) };
        const day = epoch.getDaySeconds();
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day.getHoursIntoDay(),
            day.getMinutesIntoHour(),
        }) catch "-";
    }

    pub fn display_name(self: FileEntry, buf: []u8) []const u8 {
        if (self.kind == .dir) {
            return std.fmt.bufPrint(buf, "{s}/", .{self.name}) catch self.name;
        }
        return self.name;
    }

    pub fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
        // Directories first
        const a_is_dir: u1 = if (a.kind == .dir) 0 else 1;
        const b_is_dir: u1 = if (b.kind == .dir) 0 else 1;
        if (a_is_dir != b_is_dir) return a_is_dir < b_is_dir;
        // Case-insensitive alphabetical
        return ascii_less_than(a.name, b.name);
    }
};

fn ascii_less_than(a: []const u8, b: []const u8) bool {
    const min_len = @min(a.len, b.len);
    for (a[0..min_len], b[0..min_len]) |ac, bc| {
        const al = std.ascii.toLower(ac);
        const bl = std.ascii.toLower(bc);
        if (al != bl) return al < bl;
    }
    return a.len < b.len;
}
