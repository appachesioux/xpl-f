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
    bookmark,
};

pub const ReplaceField = enum {
    find,
    replace_with,
};

pub const ClipOp = enum {
    none,
    copy,
    cut,
};
