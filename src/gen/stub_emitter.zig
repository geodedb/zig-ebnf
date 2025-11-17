const std = @import("std");
const ast = @import("../ebnf/ast.zig");

// Very small stub backend: emits functions that always fail except start rule which succeeds on empty input.
pub fn emitStub(alloc: std.mem.Allocator, grammar: *const ast.AST, start_rule: []const u8, header: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeAll(header);
    try w.writeAll("// Stub backend: recognition functions are placeholders.\n");
    try w.writeAll("const std = @import(\"std\");\n");
    for (grammar.rules) |r| {
        const line = try std.fmt.allocPrint(alloc, "fn rule_{s}() bool {{ return false; }}\n", .{r.name});
        defer alloc.free(line);
        try w.writeAll(line);
    }
    // Provide a recognizer that only accepts empty input for demonstration.
    const rec = try std.fmt.allocPrint(alloc, "pub fn recognize_{s}(input: []const u8) !void {{ if (input.len != 0) return error.Unexpected; }}\n", .{start_rule});
    defer alloc.free(rec);
    try w.writeAll(rec);
    return buf.toOwnedSlice();
}
