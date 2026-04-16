const std = @import("std");
const rt = @import("../runtime/runtime.zig");
const ast = @import("ast.zig");
const Error = ast.Error;
const lex = @import("lexer.zig");
const lib = @import("../lib.zig");

pub fn parse(alloc: std.mem.Allocator, src: []const u8) !ast.AST {
    return parseWithOpts(alloc, src, .{});
}

pub fn parseWithOpts(alloc: std.mem.Allocator, src: []const u8, opts: lib.ParseOptions) !ast.AST {
    var lx = lex.Lexer.init(alloc, src);
    lx.permissive = opts.permissive;

    // Arena for all Expr and slice allocations to simplify cleanup.
    var arena_ptr = try alloc.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(alloc);
    var arena_cancel = false;
    errdefer if (!arena_cancel) {
        arena_ptr.deinit();
        alloc.destroy(arena_ptr);
    };
    const aalloc = arena_ptr.allocator();

    var rules: std.ArrayList(ast.Rule) = .empty;
    errdefer rules.deinit(alloc);

    // Track literal value buffers allocated by the lexer so AST.deinit can free them.
    var literals: std.ArrayList([]const u8) = .empty;
    // On any error before AST construction, free each literal slice.
    errdefer {
        for (literals.items) |lit| alloc.free(lit);
        literals.deinit(alloc);
    }
    // Dedup set to avoid storing duplicate (interned) literal value slices which would double free.
    var literal_set = std.StringHashMap(void).init(alloc);
    var literal_set_active = true;
    errdefer if (literal_set_active) literal_set.deinit();

    // Collect identifier occurrences (excluding rule headers) for span-aware diagnostics.
    var ident_occurs: std.ArrayList(ast.AST.IdentOccur) = .empty;
    var ident_occurs_active = true;
    errdefer if (ident_occurs_active) ident_occurs.deinit(alloc);

    var toks: std.ArrayList(lex.Tok) = .empty;
    defer toks.deinit(alloc);

    // Tokenize entire stream once so we can attach literal values, then parse.
    while (true) {
        const t = try lx.next();
        // Capture literal buffers (value) for later freeing. The lexer allocates a slice for every literal token.
        if (t.kind == .Literal) {
            // Store only first occurrence of an interned literal; duplicates share pointer.
            if (!literal_set.contains(t.value)) {
                try literal_set.put(t.value, {});
                try literals.append(alloc, t.value);
            }
        }
        try toks.append(alloc, t);
        if (t.kind == .Eof) break;
    }
    lx.deinit();
    // literal_set will be cleaned up by errdefer cancellation below after ownership transfer.

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
        const expr_ref = try parseRhs(aalloc, toks.items, &i, &ident_occurs, alloc);
        try rules.append(alloc, .{ .name = id.lexeme, .expr = expr_ref, .span = id.span });
    }

    // Move ident occurrences into arena-owned slice (lightweight copies).
    var idents_slice: []ast.AST.IdentOccur = &[_]ast.AST.IdentOccur{};
    if (ident_occurs.items.len > 0) {
        idents_slice = try aalloc.alloc(ast.AST.IdentOccur, ident_occurs.items.len);
        for (idents_slice, 0..) |*dst, idx| dst.* = ident_occurs.items[idx];
    }
    ident_occurs.deinit(alloc); // free temp list backing buffer
    ident_occurs_active = false; // prevent double-free via errdefer
    var ast_out = ast.AST{
        .alloc = alloc,
        .src = src,
        .rules = try rules.toOwnedSlice(alloc),
        .literals = try literals.toOwnedSlice(alloc),
        .arena = arena_ptr,
        .idents = idents_slice,
    };
    // No longer need literal_set beyond this point.
    literal_set.deinit();
    literal_set_active = false;
    // Ownership has transferred to ast_out; cancel raw arena cleanup and replace with ast_out.deinit on failure.
    arena_cancel = true; // ast_out now responsible for arena lifetime
    var ast_cleanup = true;
    errdefer if (ast_cleanup) ast_out.deinit();

    // Perform early validations; if any fail error unwinds triggering ast_out.deinit via errdefer.
    try ast_out.ensureNoDuplicates();

    // In permissive mode, auto-stub any undefined nonterminals (assign empty production) so
    // large external grammars with implicit lexical tokens can be ingested. We do this
    // before calling ensureDefinedSymbols; if stubs cover all, no UndefinedSymbol error.
    if (opts.permissive) {
        // Collect undefined names first to avoid mutating while iterating.
        var undef = std.StringHashMap(rt.Span).init(alloc);
        defer undef.deinit();
        var i_u: usize = 0;
        while (i_u < ast_out.idents.len) : (i_u += 1) {
            const occ = ast_out.idents[i_u];
            if (ast_out.ruleIndex(occ.name) == null) {
                // Skip if already scheduled
                _ = try undef.fetchPut(occ.name, occ.span);
            }
        }
        if (undef.count() > 0) {
            // Move existing rules into an ArrayList to append stubs.
            var tmp_rules: std.ArrayList(ast.Rule) = .empty;
            defer tmp_rules.deinit(alloc); // converted to slice later
            try tmp_rules.appendSlice(alloc, ast_out.rules);
            alloc.free(ast_out.rules);
            var it = undef.iterator();
            while (it.next()) |e| {
                const nm = e.key_ptr.*;
                // Create empty expr node in arena.
                const expr_node = try aalloc.create(ast.Expr);
                expr_node.* = ast.Expr{ .empty = {} };
                // Mark span line=0 as synthetic stub so reachability can ignore.
                var sp = e.value_ptr.*;
                sp.line = 0;
                try tmp_rules.append(alloc, .{ .name = nm, .expr = expr_node, .span = sp });
            }
            ast_out.rules = try tmp_rules.toOwnedSlice(alloc);
        }
    }

    if (opts.permissive) {
        ast_out.ensureDefinedSymbols() catch |e| switch (e) {
            Error.UndefinedSymbol => {}, // tolerate (stubs may remain unresolved)
            else => return e,
        };
    } else try ast_out.ensureDefinedSymbols();

    // Success – caller takes ownership.
    ast_cleanup = false;
    return ast_out;
}

inline fn isRuleStart(ts: []const lex.Tok, idx: usize) bool {
    return idx + 1 < ts.len and ts[idx].kind == .Ident and ts[idx + 1].kind == .Assign;
}

fn parseRhs(alloc: std.mem.Allocator, ts: []lex.Tok, i: *usize, idents: *std.ArrayList(ast.AST.IdentOccur), idents_alloc: std.mem.Allocator) (Error || std.mem.Allocator.Error)!ast.ExprRef {
    var alts: std.ArrayList(ast.ExprRef) = .empty;
    errdefer alts.deinit(alloc);

    while (true) {
        const seq = try parseSequence(alloc, ts, i, idents, idents_alloc);
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

fn parseSequence(alloc: std.mem.Allocator, ts: []lex.Tok, i: *usize, idents: *std.ArrayList(ast.AST.IdentOccur), idents_alloc: std.mem.Allocator) (Error || std.mem.Allocator.Error)!ast.ExprRef {
    var items: std.ArrayList(ast.ExprRef) = .empty;
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
        const term = try parseTerm(alloc, ts, i, idents, idents_alloc);
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

fn parseTerm(alloc: std.mem.Allocator, ts: []lex.Tok, i: *usize, idents: *std.ArrayList(ast.AST.IdentOccur), idents_alloc: std.mem.Allocator) (Error || std.mem.Allocator.Error)!ast.ExprRef {
    const t = ts[i.*];
    switch (t.kind) {
        .Ident => {
            i.* += 1;
            const node = try alloc.create(ast.Expr);
            node.* = ast.Expr{ .ident = t.lexeme };
            try idents.append(idents_alloc, .{ .name = t.lexeme, .span = t.span });
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
            const inner = parseRhs(alloc, ts, i, idents, idents_alloc) catch |e| {
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
            const inner = parseRhs(alloc, ts, i, idents, idents_alloc) catch |e| {
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
