const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("app.zig").App;

pub const panic = vaxis.panic_handler;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const initial_dir = blk: {
        var args = std.process.args();
        _ = args.next(); // skip program name
        break :blk args.next();
    };

    const app = try App.init(allocator, initial_dir);
    defer app.deinit();

    try app.run();
}
