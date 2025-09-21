const std = @import("std");
const lib = @import("../lib.zig");

// Golden emission style test: ensures generated RD backend contains rule_ functions and recognize_ symbol.
test "golden emission rd integer grammar" {
    const gpa = std.testing.allocator;
    const src =
        \\digit   ::= "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"\n
        \\sign    ::= "+" | "-"\n
        \\integer ::= [ sign ] digit { digit }\n
    ;
    var astv = try lib.parseEbnf(gpa, src);
    defer astv.deinit();
    var gen = try lib.generateZig(gpa, &astv, .{ .backend = .RecursiveDescent, .module_name = "golden_int", .start_rule = "integer" });
    defer gen.deinit(gpa);
    // Find module file
    var mod_contents: ?[]const u8 = null;
    for (gen.files) |f| {
        if (std.mem.endsWith(u8, f.path, "/mod.zig")) mod_contents = f.contents;
    }
    try std.testing.expect(mod_contents != null);
    const mc = mod_contents.?;
    try std.testing.expect(std.mem.indexOf(u8, mc, "fn rule_digit(") != null);
    try std.testing.expect(std.mem.indexOf(u8, mc, "fn rule_integer(") != null);
    try std.testing.expect(std.mem.indexOf(u8, mc, "pub fn recognize_integer(") != null);
}
