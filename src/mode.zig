const std = @import("std");
const vaxis = @import("vaxis");

pub const Mode = enum {
    normal,
    edit,
    search,
    replace,
    confirm,
    help,
    preview,
    create,
    find,
};

pub const ReplaceField = enum {
    find,
    replace_with,
};

pub const PendingKey = enum {
    none,
    g,
    d,
    y,
};

pub const ClipOp = enum {
    none,
    copy,
    cut,
};

pub const ConfirmAction = enum {
    delete,
    apply_edits,
};

pub const EditChange = struct {
    original_name: []const u8,
    new_name: []const u8, // empty = delete
};
