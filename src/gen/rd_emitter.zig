const std = @import("std");
const ast = @import("../ebnf/ast.zig");

pub fn emitRecursiveDescent(alloc: std.mem.Allocator, grammar: *const ast.AST, start_rule: []const u8, header: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeAll(header);
    try w.writeAll("const std = @import(\"std\");\n");
    try w.writeAll("pub const RecognizerError = error{Unexpected, Trailing};\n");
    try w.writeAll(
        "const Cursor = struct { buf: []const u8, idx: usize = 0, fn atEnd(self: *const Cursor) bool { return self.idx >= self.buf.len; } fn save(self: *const Cursor) usize { return self.idx; } fn restore(self: *Cursor, m: usize) void { self.idx = m; } };\n",
    );
    try w.writeAll(
        "fn matchLit(c: *Cursor, lit: []const u8) bool { if (c.idx + lit.len > c.buf.len) return false; if (!std.mem.eql(u8, c.buf[c.idx..c.idx+lit.len], lit)) return false; c.idx += lit.len; return true; }\n",
    );

    var inline_counter: usize = 0;
    for (grammar.rules) |r| {
        try w.print("fn rule_{s}(c: *Cursor) bool ", .{r.name});
        try w.writeAll("{\n");
        try emitRuleBody(w, r.expr, 1, &inline_counter);
        try w.writeAll("}\n\n");
    }
    // Final recognizer: avoid braces in format strings by splitting pieces
    try w.print("pub fn recognize_{s}(input: []const u8) !void ", .{start_rule});
    try w.writeAll("{ var c = Cursor{ .buf = input }; ");
    try w.print("if (!rule_{s}(&c)) return RecognizerError.Unexpected; ", .{start_rule});
    try w.writeAll("if (!c.atEnd()) return RecognizerError.Trailing; }\n");
    return buf.toOwnedSlice();
}
// Statement oriented emission (simpler & clearer for initial RD backend)
fn emitRuleBody(w: anytype, e: ast.ExprRef, level: usize, counter: *usize) !void {
    switch (e.*) {
        .empty => {
            try indent(w, level);
            try w.writeAll("return true;\n");
        },
        .literal => |lit| {
            try indent(w, level);
            try w.print("return matchLit(c, \"{s}\");\n", .{lit});
        },
        .ident => |nm| {
            try indent(w, level);
            try w.print("return rule_{s}(c);\n", .{nm});
        },
        .seq => |items| try emitSeq(w, items, level, counter),
        .choice => |alts| try emitChoice(w, alts, level, counter),
        .opt => |sub| try emitOpt(w, sub, level, counter),
        .rep => |sub| try emitRep(w, sub, level, counter),
    }
}

fn indent(w: anytype, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) try w.writeAll("    ");
}

fn emitSeq(w: anytype, items: []ast.ExprRef, level: usize, counter: *usize) !void {
    if (items.len == 0) {
        try indent(w, level);
        try w.writeAll("return true;\n");
        return;
    }
    try indent(w, level);
    try w.writeAll("const m = c.save();\n");
    for (items) |it| switch (it.*) {
        .opt => |sub| try emitOptStmt(w, sub, level, counter),
        .rep => |sub| try emitRepStmt(w, sub, level, counter),
        else => {
            try indent(w, level);
            try w.writeAll("if (!");
            try emitInlineExpr(w, it, counter);
            try w.writeAll(") { c.restore(m); return false; }\n");
        },
    };
    try indent(w, level);
    try w.writeAll("return true;\n");
}

fn emitChoice(w: anytype, alts: []ast.ExprRef, level: usize, counter: *usize) !void {
    for (alts) |alt| {
        try indent(w, level);
        try w.writeAll("{ const m2 = c.save(); if (\n");
        try indent(w, level + 1);
        try emitInlineExpr(w, alt, counter);
        try w.writeAll(") { return true; } c.restore(m2); }\n");
    }
    try indent(w, level);
    try w.writeAll("return false;\n");
}

fn emitOpt(w: anytype, sub: ast.ExprRef, level: usize, counter: *usize) !void {
    try indent(w, level);
    try w.writeAll("{ const m = c.save(); if (!");
    try emitInlineExpr(w, sub, counter);
    try w.writeAll(") c.restore(m); } return true;\n");
}

fn emitRep(w: anytype, sub: ast.ExprRef, level: usize, counter: *usize) !void {
    try indent(w, level);
    try w.writeAll("while (true) { const m = c.save(); if (!");
    try emitInlineExpr(w, sub, counter);
    try w.writeAll(") { c.restore(m); break; } } return true;\n");
}

fn emitOptStmt(w: anytype, sub: ast.ExprRef, level: usize, counter: *usize) !void {
    try indent(w, level);
    try w.writeAll("{ const m1 = c.save(); if (!");
    try emitInlineExpr(w, sub, counter);
    try w.writeAll(") c.restore(m1); }\n");
}

fn emitRepStmt(w: anytype, sub: ast.ExprRef, level: usize, counter: *usize) !void {
    try indent(w, level);
    try w.writeAll("while (true) { const m1 = c.save(); if (!");
    try emitInlineExpr(w, sub, counter);
    try w.writeAll(") { c.restore(m1); break; } }\n");
}

fn emitInlineExpr(w: anytype, e: ast.ExprRef, counter: *usize) !void {
    switch (e.*) {
        .empty => try w.writeAll("true"),
        .literal => |lit| try w.print("matchLit(c, \"{s}\")", .{lit}),
        .ident => |nm| try w.print("rule_{s}(c)", .{nm}),
        .seq => |items| inlineSeq(w, items, counter),
        .choice => |alts| inlineChoice(w, alts, counter),
        .opt => |sub| inlineOpt(w, sub, counter),
        .rep => |sub| inlineRep(w, sub, counter),
    }
}

fn inlineSeq(w: anytype, items: []ast.ExprRef, counter: *usize) void {
    const id = counter.*;
    counter.* += 1;
    w.writeAll("(blk") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(": { const sv") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(" = c.save();") catch return;
    for (items) |it| {
        w.writeAll(" if (!") catch return;
        emitInlineExpr(w, it, counter) catch return;
        w.writeAll(") { c.restore(sv") catch return;
        w.print("{d}", .{id}) catch return;
        w.writeAll("); break :blk") catch return;
        w.print("{d}", .{id}) catch return;
        w.writeAll(" false; }") catch return;
    }
    w.writeAll(" break :blk") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(" true; })") catch return;
}

fn inlineChoice(w: anytype, alts: []ast.ExprRef, counter: *usize) void {
    const id = counter.*;
    counter.* += 1;
    w.writeAll("(blk") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(": { const sv") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(" = c.save();") catch return;
    var i: usize = 0;
    while (i < alts.len) : (i += 1) {
        if (i > 0) {
            w.writeAll(" c.restore(sv") catch return;
            w.print("{d}", .{id}) catch return;
            w.writeAll(");") catch return;
        }
        w.writeAll(" if (") catch return;
        emitInlineExpr(w, alts[i], counter) catch return;
        w.writeAll(") break :blk") catch return;
        w.print("{d}", .{id}) catch return;
        w.writeAll(" true;") catch return;
    }
    w.writeAll(" break :blk") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(" false; })") catch return;
}

fn inlineOpt(w: anytype, sub: ast.ExprRef, counter: *usize) void {
    const id = counter.*;
    counter.* += 1;
    w.writeAll("(blk") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(": { const sv") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(" = c.save(); if (!") catch return;
    emitInlineExpr(w, sub, counter) catch return;
    w.writeAll(") c.restore(sv") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll("); break :blk") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(" true; })") catch return;
}

fn inlineRep(w: anytype, sub: ast.ExprRef, counter: *usize) void {
    const id = counter.*;
    counter.* += 1;
    w.writeAll("(blk") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(": { while (true) { const sv") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(" = c.save(); if (!") catch return;
    emitInlineExpr(w, sub, counter) catch return;
    w.writeAll(") { c.restore(sv") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll("); break; } } break :blk") catch return;
    w.print("{d}", .{id}) catch return;
    w.writeAll(" true; })") catch return;
}
