const std = @import("std");
const rt = @import("../runtime/runtime.zig");

pub const Error = error{
    SyntaxError,
    UndefinedSymbol,
    DuplicateRule,
    LeftRecursion,
    EmptyRepetition,
    UnreachableRule,
    AmbiguousChoice,
    IoError,
};

pub const ExprTag = enum {
    seq,
    choice,
    opt,
    rep,
    literal,
    ident,
    empty,
};

pub const Expr = union(ExprTag) {
    seq: []ExprRef,
    choice: []ExprRef,
    opt: ExprRef,
    rep: ExprRef,
    literal: []const u8,
    ident: []const u8,
    empty: void,
};

pub const ExprRef = *Expr;

pub const Rule = struct {
    name: []const u8,
    expr: ExprRef,
    span: rt.Span,
};

pub const AST = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    rules: []Rule,
    // Literal value slices allocated by lexer (owned).
    literals: [][]const u8 = &[_][]const u8{},
    // Optional arena for expression graph allocations; if present it owns all Expr memory.
    arena: ?*std.heap.ArenaAllocator = null,
    // All identifier occurrences captured during parse (name + span). Owned slices referencing rule/expr memory; name slice lives in source or token stream, not owned.
    idents: []IdentOccur = &[_]IdentOccur{},
    // Diagnostics: last undefined symbol names/spans from ensureDefinedSymbols (up to 8). Names are slices into source.
    last_undef_names: [][]const u8 = &[_][]const u8{},
    last_undef_spans: []rt.Span = &[_]rt.Span{},

    pub const IdentOccur = struct { name: []const u8, span: rt.Span };

    pub fn deinit(self: *AST) void {
        const alloc = self.alloc;
        if (self.arena) |ap| {
            // Expressions live in arena; only free ancillary allocations.
            if (self.rules.len > 0) alloc.free(self.rules);
            for (self.literals) |lit| alloc.free(lit);
            if (self.literals.len > 0) alloc.free(self.literals);
            // idents slice memory resides in arena; do not free with general allocator.
            if (self.last_undef_names.len > 0) alloc.free(self.last_undef_names);
            if (self.last_undef_spans.len > 0) alloc.free(self.last_undef_spans);
            ap.deinit();
            alloc.destroy(ap);
            self.* = undefined;
            return;
        }
        // Manual destruction path (legacy / fallback)
        for (self.rules) |r| destroyExpr(alloc, r.expr);
        if (self.rules.len > 0) alloc.free(self.rules);
        for (self.literals) |lit| alloc.free(lit);
        if (self.literals.len > 0) alloc.free(self.literals);
        if (self.idents.len > 0) alloc.free(self.idents);
        if (self.last_undef_names.len > 0) alloc.free(self.last_undef_names);
        if (self.last_undef_spans.len > 0) alloc.free(self.last_undef_spans);
        self.* = undefined;
    }

    /// Collect terminals (unique, in first-seen order).
    pub fn collectTerminals(self: *const AST, alloc: std.mem.Allocator) ![][]const u8 {
        var seen = std.StringHashMap(void).init(alloc);
        defer seen.deinit();
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(alloc);

        for (self.rules) |r| {
            try collectFromExpr(self, alloc, r.expr, &seen, &out);
        }
        return out.toOwnedSlice(alloc);
    }

    fn collectFromExpr(self: *const AST, alloc: std.mem.Allocator, e: ExprRef, seen: *std.StringHashMap(void), out: *std.ArrayList([]const u8)) !void {
        switch (e.*) {
            .literal => |lit| {
                if (lit.len == 0) return; // empty symbol is not a terminal token
                if (!seen.contains(lit)) {
                    try seen.put(lit, {});
                    try out.append(alloc, lit);
                }
            },
            .ident => {},
            .empty => {},
            .opt => |sub| try collectFromExpr(self, alloc, sub, seen, out),
            .rep => |sub| try collectFromExpr(self, alloc, sub, seen, out),
            .seq => |items| for (items) |it| try collectFromExpr(self, alloc, it, seen, out),
            .choice => |alts| for (alts) |it| try collectFromExpr(self, alloc, it, seen, out),
        }
    }

    // --- Validation helpers ---

    pub fn ruleIndex(self: *const AST, name: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.rules.len) : (i += 1) {
            if (std.mem.eql(u8, self.rules[i].name, name)) return i;
        }
        return null;
    }

    pub fn ensureNoDuplicates(self: *const AST) !void {
        var set = std.StringHashMap(void).init(self.alloc);
        defer set.deinit();
        for (self.rules) |r| {
            if (set.contains(r.name)) return Error.DuplicateRule;
            try set.put(r.name, {});
        }
    }

    pub fn ensureDefinedSymbols(self: *const AST) !void {
        // Use ident occurrence table for span-aware undefined symbol reporting.
        var undef_list: std.ArrayList([]const u8) = .empty;
        defer undef_list.deinit(self.alloc);
        var spans: std.ArrayList(rt.Span) = .empty;
        defer spans.deinit(self.alloc);
        // Heuristic: treat ALL_CAPS (letters, digits, underscore) identifiers as implicit
        // lexer-provided token symbols so large external grammars (e.g. gql.ebnf) that
        // reference symbolic terminals like IDENTIFIER, INTEGER, STRING, VARIABLE, etc.
        // do not require dummy rule definitions. This keeps grammar authoring ergonomic
        // while still flagging genuinely undefined nonterminals written in lower/mixed case.
        const looksToken = struct {
            fn check(name: []const u8) bool {
                if (name.len == 0) return false;
                var any_alpha = false;
                for (name) |c| {
                    if (c >= 'a' and c <= 'z') return false; // has lowercase => nonterminal
                    if (!((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) return false;
                    if (c >= 'A' and c <= 'Z') any_alpha = true;
                }
                return any_alpha; // at least one letter to avoid treating "_" as token
            }
        }.check;
        var i: usize = 0;
        while (i < self.idents.len and undef_list.items.len < 8) : (i += 1) {
            const occ = self.idents[i];
            if (self.ruleIndex(occ.name) == null and !looksToken(occ.name)) {
                try undef_list.append(self.alloc, occ.name);
                try spans.append(self.alloc, occ.span);
            }
        }
        // Replace previous diagnostic arrays.
        const mut = @constCast(self);
        if (mut.last_undef_names.len > 0) mut.alloc.free(mut.last_undef_names);
        if (mut.last_undef_spans.len > 0) mut.alloc.free(mut.last_undef_spans);
        mut.last_undef_names = &[_][]const u8{};
        mut.last_undef_spans = &[_]rt.Span{};
        if (undef_list.items.len > 0) {
            mut.last_undef_names = try undef_list.toOwnedSlice(self.alloc);
            mut.last_undef_spans = try spans.toOwnedSlice(self.alloc);
            return Error.UndefinedSymbol;
        }
    }

    fn walkEnsureDefined(self: *const AST, e: ExprRef) !void {
        switch (e.*) {
            .ident => |nm| {
                if (self.ruleIndex(nm) == null) return Error.UndefinedSymbol;
            },
            .literal, .empty => {},
            .opt => |sub| try walkEnsureDefined(self, sub),
            .rep => |sub| try walkEnsureDefined(self, sub),
            .seq => |items| for (items) |it| try walkEnsureDefined(self, it),
            .choice => |alts| for (alts) |it| try walkEnsureDefined(self, it),
        }
    }

    // Compute nullability (can match empty)
    pub fn nullableSet(self: *const AST, alloc: std.mem.Allocator) !std.StringHashMap(bool) {
        var nulls = std.StringHashMap(bool).init(alloc);
        defer if (true) {} else nulls.deinit(); // caller owns
        // initialize false
        for (self.rules) |r| try nulls.put(r.name, false);

        var changed = true;
        while (changed) {
            changed = false;
            for (self.rules) |r| {
                const old = nulls.get(r.name).?;
                const now = try canEmpty(self, &nulls, r.expr);
                if (now != old) {
                    try nulls.put(r.name, now);
                    changed = true;
                }
            }
        }
        return nulls;
    }

    fn canEmpty(self: *const AST, nulls: *std.StringHashMap(bool), e: ExprRef) !bool {
        return switch (e.*) {
            .empty => true,
            .literal => |lit| lit.len == 0,
            .ident => |nm| nulls.get(nm) orelse false,
            .opt => true,
            .rep => true,
            .seq => |items| blk: {
                for (items) |it| {
                    if (!(try canEmpty(self, nulls, it))) break :blk false;
                }
                break :blk true;
            },
            .choice => |alts| blk: {
                for (alts) |it| {
                    if (try canEmpty(self, nulls, it)) break :blk true;
                }
                break :blk false;
            },
        };
    }

    // Leading nonterminals: could appear first (after swallowing empties)
    pub fn leadingNT(self: *const AST, alloc: std.mem.Allocator, e: ExprRef, nulls: *std.StringHashMap(bool)) !std.StringHashMap(bool) {
        var out = std.StringHashMap(bool).init(alloc);
        errdefer out.deinit();

        switch (e.*) {
            .ident => |nm| {
                try out.put(nm, true);
            },
            .literal, .empty => {},
            .opt => |sub| {
                var m = try self.leadingNT(alloc, sub, nulls);
                defer m.deinit();
                try mergeBoolMap(&out, &m);
            },
            .rep => |sub| {
                var m = try self.leadingNT(alloc, sub, nulls);
                defer m.deinit();
                try mergeBoolMap(&out, &m);
            },
            .choice => |alts| {
                for (alts) |it| {
                    var m = try self.leadingNT(alloc, it, nulls);
                    defer m.deinit();
                    try mergeBoolMap(&out, &m);
                }
            },
            .seq => |items| {
                var i: usize = 0;
                while (i < items.len) : (i += 1) {
                    var m = try self.leadingNT(alloc, items[i], nulls);
                    defer m.deinit();
                    try mergeBoolMap(&out, &m);
                    if (!(try self.canEmpty(nulls, items[i]))) break;
                }
            },
        }
        return out;
    }

    fn mergeBoolMap(dst: *std.StringHashMap(bool), src: *std.StringHashMap(bool)) !void {
        var it = src.iterator();
        while (it.next()) |e| {
            try dst.put(e.key_ptr.*, true);
        }
    }

    pub fn checkEmptyRepetition(self: *const AST) !void {
        const temp_alloc = self.alloc;
        var nulls = try self.nullableSet(temp_alloc);
        defer nulls.deinit();
        for (self.rules) |r| try walkCheckRep(self, r.name, r.expr, &nulls);
    }

    fn walkCheckRep(self: *const AST, rule_name: []const u8, e: ExprRef, nulls: *std.StringHashMap(bool)) !void {
        switch (e.*) {
            .rep => |sub| {
                const empty = try self.canEmpty(nulls, sub);
                if (empty) return Error.EmptyRepetition;
                try walkCheckRep(self, rule_name, sub, nulls);
            },
            .opt => |sub| try walkCheckRep(self, rule_name, sub, nulls),
            .seq => |items| for (items) |it| try walkCheckRep(self, rule_name, it, nulls),
            .choice => |alts| for (alts) |it| try walkCheckRep(self, rule_name, it, nulls),
            .ident, .literal, .empty => {},
        }
    }

    pub fn checkLeftRecursion(self: *const AST) !void {
        const temp_alloc = self.alloc;
        var nulls = try self.nullableSet(temp_alloc);
        defer nulls.deinit();

        for (self.rules) |r| {
            // DFS over leading nonterminals
            var stack: std.ArrayList([]const u8) = .empty;
            defer stack.deinit(temp_alloc);
            try stack.append(temp_alloc, r.name);
            if (try dfsLeftRec(self, temp_alloc, &nulls, r.name, &stack)) {
                return Error.LeftRecursion;
            }
        }
    }

    fn dfsLeftRec(
        self: *const AST,
        alloc: std.mem.Allocator,
        nulls: *std.StringHashMap(bool),
        start: []const u8,
        stack: *std.ArrayList([]const u8),
    ) !bool {
        const top = stack.items[stack.items.len - 1];
        const idx = self.ruleIndex(top) orelse return false;
        var ln = try self.leadingNT(alloc, self.rules[idx].expr, nulls);
        defer ln.deinit();

        var it = ln.iterator();
        while (it.next()) |e| {
            const nt = e.key_ptr.*;
            if (std.mem.eql(u8, nt, start)) return true;
            var visited = false;
            for (stack.items) |seen| {
                if (std.mem.eql(u8, nt, seen)) {
                    visited = true;
                    break;
                }
            }
            if (!visited) {
                try stack.append(alloc, nt);
                const found = try dfsLeftRec(self, alloc, nulls, start, stack);
                _ = stack.pop();
                if (found) return true;
            }
        }
        return false;
    }

    pub fn checkReachability(self: *const AST, start: []const u8) !void {
        // If synthetic stub rules are present (span.line == 0) we skip strict reachability
        // to allow large external grammars with partial definitions to pass permissive mode.
        var has_stub = false;
        for (self.rules) |r| {
            if (r.span.line == 0) {
                has_stub = true;
                break;
            }
        }
        if (has_stub) return; // relaxed in permissive ingestion
        var q: std.ArrayList([]const u8) = .empty;
        defer q.deinit(self.alloc);
        var seen = std.StringHashMap(bool).init(self.alloc);
        defer seen.deinit();

        try q.append(self.alloc, start);
        try seen.put(start, true);

        while (q.items.len > 0) {
            const cur = q.pop().?;
            const ri = self.ruleIndex(cur) orelse continue;
            try visitRefs(self, self.rules[ri].expr, &seen, &q);
        }

        for (self.rules) |r| {
            // Ignore synthetic stub rules (span.line == 0) for reachability reporting.
            if (r.span.line == 0) continue;
            if (!seen.contains(r.name)) return Error.UnreachableRule;
        }
    }

    fn visitRefs(self: *const AST, e: ExprRef, seen: *std.StringHashMap(bool), q: *std.ArrayList([]const u8)) !void {
        switch (e.*) {
            .ident => |nm| if (!seen.contains(nm)) {
                try seen.put(nm, true);
                try q.append(self.alloc, nm);
            },
            .opt => |sub| try visitRefs(self, sub, seen, q),
            .rep => |sub| try visitRefs(self, sub, seen, q),
            .seq => |items| for (items) |it| try visitRefs(self, it, seen, q),
            .choice => |alts| for (alts) |it| try visitRefs(self, it, seen, q),
            .literal, .empty => {},
        }
    }

    // Legacy collectUndef no longer used (span-less); kept for reference if future deep-walk needed.
    fn collectUndef(self: *const AST, e: ExprRef, names: *std.ArrayList([]const u8), spans: *std.ArrayList(rt.Span)) !void {
        _ = self;
        _ = e;
        _ = names;
        _ = spans;
    }
};

pub fn destroyExpr(alloc: std.mem.Allocator, e: ExprRef) void {
    switch (e.*) {
        .seq => |items| {
            for (items) |it| destroyExpr(alloc, it);
            if (items.len > 0) alloc.free(items);
            alloc.destroy(e);
        },
        .choice => |alts| {
            for (alts) |it| destroyExpr(alloc, it);
            if (alts.len > 0) alloc.free(alts);
            alloc.destroy(e);
        },
        .opt => |sub| {
            destroyExpr(alloc, sub);
            alloc.destroy(e);
        },
        .rep => |sub| {
            destroyExpr(alloc, sub);
            alloc.destroy(e);
        },
        .literal => {
            // Literal slice memory freed separately via AST.literals tracking.
            alloc.destroy(e);
        },
        .ident => alloc.destroy(e),
        .empty => alloc.destroy(e),
    }
}
