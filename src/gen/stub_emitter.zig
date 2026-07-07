const std = @import("std");
const ast = @import("../ebnf/ast.zig");

// Very small stub backend: emits functions that always fail except start rule which succeeds on empty input.
pub fn emitStub(alloc: std.mem.Allocator, grammar: *const ast.AST, start_rule: []const u8, header: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, header);
    try buf.appendSlice(alloc, "// Stub backend: recognition functions are placeholders.\n");
    try buf.appendSlice(alloc, "const std = @import(\"std\");\n");
    for (grammar.rules) |r| {
        const line = try std.fmt.allocPrint(alloc, "fn rule_{s}() bool {{ return false; }}\n", .{r.name});
        defer alloc.free(line);
        try buf.appendSlice(alloc, line);
    }
    // Provide a recognizer that only accepts empty input for demonstration.
    const rec = try std.fmt.allocPrint(alloc, "pub fn recognize_{s}(input: []const u8) !void {{ if (input.len != 0) return error.Unexpected; }}\n", .{start_rule});
    defer alloc.free(rec);
    try buf.appendSlice(alloc, rec);
    return buf.toOwnedSlice(alloc);
}
