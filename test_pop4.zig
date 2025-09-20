const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(allocator);
    const val = if (list.items.len > 0) list.pop() else null;
    _ = val;
}
