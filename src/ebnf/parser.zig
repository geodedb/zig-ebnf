const std = @import("std");
const rt = @import("../runtime/runtime.zig");
const ast = @import("ast.zig");
const Error = ast.Error;
const lex = @import("lexer.zig");

pub fn parse(alloc: std.mem.Allocator, src: []const u8) !ast.AST {
    var lx = lex.Lexer.init(alloc, src);

    // Arena for all Expr and slice allocations to simplify cleanup.
    var arena_ptr = try alloc.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(alloc);
    errdefer {
        arena_ptr.deinit();
        alloc.destroy(arena_ptr);
    }
    const aalloc = arena_ptr.allocator();

    var rules: std.ArrayList(ast.Rule) = .{};
    errdefer rules.deinit(alloc);

    // Track literal value buffers allocated by the lexer so AST.deinit can free them.
    var literals: std.ArrayList([]const u8) = .{};
    // On any error before AST construction, free each literal slice.
    errdefer {
        for (literals.items) |lit| alloc.free(lit);
        literals.deinit(alloc);
    }

    var toks: std.ArrayList(lex.Tok) = .{};
    defer toks.deinit(alloc);

    // Tokenize entire stream once so we can attach literal values, then parse.
    while (true) {
        const t = try lx.next();
        // Capture literal buffers (value) for later freeing. The lexer allocates a slice for every literal token.
        if (t.kind == .Literal) {
            // Store the owned value slice so AST.deinit can free it.
            try literals.append(alloc, t.value);
        }
        try toks.append(alloc, t);
        if (t.kind == .Eof) break;
    }

    var i: usize = 0;
    const peek = struct {
        fn at(ts: []lex.Tok, idx: usize) lex.Tok {
            return ts[@min(idx, ts.len - 1)];
        }
    }.at;

    const expect = struct {
        fn take(ts: []lex.Tok, idx: *usize, kind: lex.Kind) !lex.Tok {
            if (peek(ts, idx.*).kind != kind) return Error.SyntaxError;
            const t = ts[idx.*];
            idx.* += 1;
            return t;
        }
        fn maybe(ts: []lex.Tok, idx: *usize, kind: lex.Kind) bool {
            if (peek(ts, idx.*).kind == kind) {
                idx.* += 1;
                return true;
            }
            return false;
        }
    };

    while (peek(toks.items, i).kind != .Eof) {
        const id = try expect.take(toks.items, &i, .Ident);
        if (!(expect.maybe(toks.items, &i, .Assign))) return Error.SyntaxError;
        const expr_ref = try parseRhs(aalloc, toks.items, &i);
        try rules.append(alloc, .{ .name = id.lexeme, .expr = expr_ref, .span = id.span });
    }

    var ast_out = ast.AST{ .alloc = alloc, .src = src, .rules = try rules.toOwnedSlice(alloc), .literals = try literals.toOwnedSlice(alloc), .arena = arena_ptr };
    try ast_out.ensureNoDuplicates();
    try ast_out.ensureDefinedSymbols();
    // Note: other validations are performed during generation and CLI recognition flows too.
    return ast_out;
}

inline fn isRuleStart(ts: []const lex.Tok, idx: usize) bool {
    return idx + 1 < ts.len and ts[idx].kind == .Ident and ts[idx + 1].kind == .Assign;
}

fn parseRhs(alloc: std.mem.Allocator, ts: []lex.Tok, i: *usize) (Error || std.mem.Allocator.Error)!ast.ExprRef {
    var alts: std.ArrayList(ast.ExprRef) = .{};
    errdefer alts.deinit(alloc);

    while (true) {
        const seq = try parseSequence(alloc, ts, i);
        try alts.append(alloc, seq);
        if (ts[i.*].kind == .Pipe) {
            i.* += 1;
            continue;
        }
        break;
    }

    if (alts.items.len == 1) {
        const only = alts.items[0];
        // Free backing buffer of temporary list (child expr itself owned by caller).
        alts.deinit(alloc);
        return only;
    }
    const node = try alloc.create(ast.Expr);
    node.* = ast.Expr{ .choice = try alts.toOwnedSlice(alloc) };
    return node;
}

fn parseSequence(alloc: std.mem.Allocator, ts: []lex.Tok, i: *usize) (Error || std.mem.Allocator.Error)!ast.ExprRef {
    var items: std.ArrayList(ast.ExprRef) = .{};
    errdefer items.deinit(alloc);

    while (true) {
        const t = ts[i.*];
        switch (t.kind) {
            .Ident => {
                // Lookahead for rule start (Ident Assign) – do not consume as part of sequence.
                if (i.* + 1 < ts.len and ts[i.* + 1].kind == .Assign) break;
            },
            .Literal, .LBracket, .LBrace => {},
            else => break,
        }
        const term = try parseTerm(alloc, ts, i);
        try items.append(alloc, term);
    }

    if (items.items.len == 0) {
        const node = try alloc.create(ast.Expr);
        node.* = ast.Expr{ .empty = {} };
        return node;
    }

    if (items.items.len == 1) {
        const only = items.items[0];
        items.deinit(alloc); // free backing buffer
        return only;
    }
    const node = try alloc.create(ast.Expr);
    node.* = ast.Expr{ .seq = try items.toOwnedSlice(alloc) };
    return node;
}

fn parseTerm(alloc: std.mem.Allocator, ts: []lex.Tok, i: *usize) (Error || std.mem.Allocator.Error)!ast.ExprRef {
    const t = ts[i.*];
    switch (t.kind) {
        .Ident => {
            i.* += 1;
            const node = try alloc.create(ast.Expr);
            node.* = ast.Expr{ .ident = t.lexeme };
            return node;
        },
        .Literal => {
            i.* += 1;
            const node = try alloc.create(ast.Expr);
            // "": empty symbol per dialect
            node.* = if (t.value.len == 0) ast.Expr{ .empty = {} } else ast.Expr{ .literal = t.value };
            return node;
        },
        .LBracket => {
            i.* += 1;
            const inner = parseRhs(alloc, ts, i) catch |e| {
                return e; // nothing allocated yet to free
            };
            if (ts[i.*].kind != .RBracket) return Error.SyntaxError;
            i.* += 1;
            const node = try alloc.create(ast.Expr);
            node.* = ast.Expr{ .opt = inner };
            return node;
        },
        .LBrace => {
            i.* += 1;
            const inner = parseRhs(alloc, ts, i) catch |e| {
                return e;
            };
            if (ts[i.*].kind != .RBrace) return Error.SyntaxError;
            i.* += 1;
            const node = try alloc.create(ast.Expr);
            node.* = ast.Expr{ .rep = inner };
            return node;
        },
        else => return Error.SyntaxError,
    }
}
