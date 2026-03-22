const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const hlp_dep = b.dependency("hlp", .{
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "app_name", "xpl-f");

    const exe = b.addExecutable(.{
        // .name = "xpl-f",
        .name = switch (target.result.os.tag) {
            // .linux => "xpl-f-linux",
            .macos => "xpl-f-macos",
            .windows => "xpl-f-windows",
            else => "xpl-f",
        },
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
                .{ .name = "hlp", .module = hlp_dep.module("hlp") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run xpl-f");
    run_step.dependOn(&run_cmd.step);
}
