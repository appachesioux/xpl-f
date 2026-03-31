const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("app.zig").App;

pub const panic = vaxis.panic_handler;

fn resolve_bookmark_alias(arg: []const u8) ?[]const u8 {
    // If arg looks like a path, don't resolve as alias
    if (arg.len == 0) return null;
    if (arg[0] == '/' or arg[0] == '.' or arg[0] == '~') return null;

    // Try to find alias in bookmarks file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse return null;
    const bk_path = std.fmt.bufPrint(&path_buf, "{s}/.config/xpl-f/bookmarks", .{home}) catch return null;

    const file = std.fs.openFileAbsolute(bk_path, .{}) catch return null;
    defer file.close();

    var buf: [64 * 1024]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    if (n == 0) return null;
    const content = buf[0..n];

    var start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            const line = content[start..i];
            if (match_alias(line, arg)) |path| return path;
            start = i + 1;
        }
    }
    if (start < content.len) {
        if (match_alias(content[start..], arg)) |path| return path;
    }
    return null;
}

fn match_alias(line: []const u8, alias: []const u8) ?[]const u8 {
    if (line.len == 0) return null;
    const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    if (eq_pos == 0 or eq_pos + 1 >= line.len) return null;
    const line_alias = line[0..eq_pos];
    const path = line[eq_pos + 1 ..];
    if (std.mem.eql(u8, line_alias, alias) and path.len > 0 and path[0] == '/') {
        return path;
    }
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const initial_dir: ?[]const u8 = blk: {
        var args = std.process.args();
        _ = args.next(); // skip program name
        const arg = args.next() orelse break :blk null;
        // Try resolving as bookmark alias first
        if (resolve_bookmark_alias(arg)) |resolved| break :blk resolved;
        break :blk arg;
    };

    const app = try App.init(allocator, initial_dir);
    defer app.deinit();

    try app.run();
}
