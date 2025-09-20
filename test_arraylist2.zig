const std = @import("std");
pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var list: std.ArrayList(u8) = std.ArrayList(u8){};
    list.allocator = allocator;
    defer list.deinit();
}
