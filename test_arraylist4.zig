const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var list = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer list.deinit();
}
