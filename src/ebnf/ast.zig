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

    pub fn deinit(self: *AST) void {
        const alloc = self.alloc;
        if (self.arena) |ap| {
            // Expressions live in arena; only free ancillary allocations.
            if (self.rules.len > 0) alloc.free(self.rules);
            for (self.literals) |lit| alloc.free(lit);
            if (self.literals.len > 0) alloc.free(self.literals);
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
        self.* = undefined;
    }

    /// Collect terminals (unique, in first-seen order).
    pub fn collectTerminals(self: *const AST, alloc: std.mem.Allocator) ![][]const u8 {
        var seen = std.StringHashMap(void).init(alloc);
        defer seen.deinit();
        var out: std.ArrayList([]const u8) = .{};
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
        for (self.rules) |r| {
            if (self.ruleIndex(r.name) == null) return Error.UndefinedSymbol; // defensive: shouldn't happen
            try walkEnsureDefined(self, r.expr);
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
            var stack: std.ArrayList([]const u8) = .{};
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
        var q: std.ArrayList([]const u8) = .{};
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
        .literal => |_| {
            // Literal slice memory freed separately via AST.literals tracking.
            alloc.destroy(e);
        },
        .ident => |_| alloc.destroy(e),
        .empty => |_| alloc.destroy(e),
    }
}
