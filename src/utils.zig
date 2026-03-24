pub fn maxOf(comptime T: type, items: []const T, comptime measure: fn (T) usize) usize {
    var max: usize = 0;
    for (items) |item| {
        const val = measure(item);
        if (val > max) max = val;
    }
    return max;
}
