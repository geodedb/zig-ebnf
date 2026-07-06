const std = @import("std");
const bnf = @import("bnf.zig");

/// Supplies the discrete decisions (`choice` alt index, `opt` take/skip,
/// `rep` continue/stop) that drive generation. The `bytes` variant is meant
/// to be fed directly from a fuzzer's input buffer: it consumes one byte per
/// decision and, once exhausted, returns 0 forever — which always selects the
/// first/shortest alternative, so generation naturally collapses toward the
/// minimal derivation and terminates.
pub const ChoiceSource = union(enum) {
    bytes: struct { data: []const u8, idx: usize = 0 },
    prng: *std.Random.DefaultPrng,

    pub fn next(self: *ChoiceSource, n: u32) u32 {
        if (n <= 1) return 0;
        switch (self.*) {
            .bytes => |*b| {
                if (b.idx >= b.data.len) return 0;
                const v = b.data[b.idx];
                b.idx += 1;
                return v % n;
            },
            .prng => |p| return p.random().uintLessThan(u32, n),
        }
    }
};

/// Rule name -> pool of replacement token strings. When generation reaches an
/// overridden rule it emits one pool entry (selected via the ChoiceSource)
/// instead of descending into the rule's body.
pub const Overrides = std.StringArrayHashMapUnmanaged([]const []const u8);

pub const GenOptions = struct {
    start: []const u8,
    max_depth: u32 = 64,
    max_len: usize = 8192,
    overrides: ?*const Overrides = null,
};

pub const GenError = error{ UnknownRule, NoFiniteDerivation, OutOfMemory };

/// Fixpoint minimal-derivation cost per rule: terminals (`keyword`/`char`)
/// cost 1, `impl_defined` costs 0, `opt` costs 0 (it can always be skipped),
/// `group`/`rep` cost their child's cost (rep must fire at least once),
/// `seq` is the saturating sum of its children, `choice` is the min over its
/// alternatives, and `nonterm` costs whatever its target rule currently
/// costs PLUS 1 for the indirection itself (undefined references — which
/// validated grammars won't have — cost 1 before that +1). Charging for the
/// indirection is what makes minimal-cost descent strictly decrease at every
/// nonterm hop: without it, a unit-production cycle like `<a> ::= <b> | X`
/// with `<b> ::= <a>` ties both alternatives of `<a>` at cost 1 and the
/// first-alt tie-break in `minCostIndex` recurses forever. With the +1,
/// the escape alternative is strictly cheaper, so the cycle always resolves.
/// Rules unreachable from a finite derivation settle at
/// `std.math.maxInt(u32)`.
pub fn minCost(g: *const bnf.Grammar, gpa: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(u32) {
    var costs: std.StringArrayHashMapUnmanaged(u32) = .{};
    errdefer costs.deinit(gpa);
    for (g.rules.keys()) |name| {
        try costs.put(gpa, name, std.math.maxInt(u32));
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (g.rules.keys(), g.rules.values()) |name, node| {
            const new_cost = nodeCost(node, &costs);
            const gop = costs.getPtr(name).?;
            if (gop.* != new_cost) {
                gop.* = new_cost;
                changed = true;
            }
        }
    }
    return costs;
}

fn satAdd(a: u32, b: u32) u32 {
    return std.math.add(u32, a, b) catch std.math.maxInt(u32);
}

fn nodeCost(n: *const bnf.Node, costs: *const std.StringArrayHashMapUnmanaged(u32)) u32 {
    return switch (n.*) {
        .keyword, .char => 1,
        .impl_defined => 0,
        .opt => 0,
        .group, .rep => |k| nodeCost(k, costs),
        .seq => |kids| blk: {
            var total: u32 = 0;
            for (kids) |k| total = satAdd(total, nodeCost(k, costs));
            break :blk total;
        },
        .choice => |alts| blk: {
            var best: u32 = std.math.maxInt(u32);
            for (alts) |a| best = @min(best, nodeCost(a, costs));
            break :blk best;
        },
        // +1 charges for the indirection itself so minimal-cost descent
        // strictly decreases across nonterm hops (see doc comment above).
        .nonterm => |name| satAdd(costs.get(name) orelse 1, 1),
    };
}

const Gen = struct {
    gpa: std.mem.Allocator,
    g: *const bnf.Grammar,
    opts: GenOptions,
    cs: *ChoiceSource,
    costs: *const std.StringArrayHashMapUnmanaged(u32),
    out: std.ArrayListUnmanaged(u8) = .{},
    depth: u32 = 0,

    // Termination rests on two cost invariants, not on a depth ceiling:
    // (1) `nodeCost` charges +1 per nonterm indirection, so the minimal-cost
    //     path selected once `overBudget()` trips strictly decreases in
    //     remaining cost at every hop and must bottom out; and
    // (2) `genNode` never descends into an infinite-cost (maxInt) region —
    //     `.choice` replaces an infinite-cost pick with the minimal-cost
    //     alternative and `.opt` skips an infinite-cost child — so every
    //     region ever entered has a finite derivation, and every nonterm hop
    //     inside it raises `depth` toward the `max_depth` trip point.
    // (A previous revision carried a redundant `4 * max_depth + 64` "hard
    // ceiling" here; it was dead code — `depth > max_depth` in the same
    // check always fired first — and could not have stopped bare seq/nonterm
    // recursion anyway, so it was removed rather than kept as false safety.)
    fn overBudget(self: *const Gen) bool {
        return self.depth > self.opts.max_depth or self.out.items.len > self.opts.max_len;
    }

    fn emitToken(self: *Gen, tok: []const u8) !void {
        if (tok.len == 0) return;
        if (self.out.items.len != 0) try self.out.append(self.gpa, ' ');
        try self.out.appendSlice(self.gpa, tok);
    }

    fn genRule(self: *Gen, name: []const u8) GenError!void {
        if (self.opts.overrides) |ov| {
            if (ov.get(name)) |pool| {
                // An override entry with an empty pool is treated as "no
                // override": fall through to the rule's normal expansion
                // below rather than emitting nothing.
                if (pool.len != 0) {
                    const idx = self.cs.next(@intCast(pool.len));
                    try self.emitToken(pool[idx]);
                    return;
                }
            }
        }
        const node = self.g.find(name) orelse return error.UnknownRule;
        try self.genNode(node);
    }

    fn genNode(self: *Gen, n: *const bnf.Node) GenError!void {
        switch (n.*) {
            .keyword => |kw| try self.emitToken(kw),
            .char => |c| {
                if (c != ' ') try self.emitToken(&[1]u8{c});
            },
            .impl_defined => {},
            .nonterm => |name| {
                self.depth += 1;
                defer self.depth -= 1;
                try self.genRule(name);
            },
            .seq => |kids| for (kids) |k| try self.genNode(k),
            .group => |k| try self.genNode(k),
            .choice => |alts| {
                var idx = if (self.overBudget())
                    minCostIndex(alts, self.costs)
                else
                    self.cs.next(@intCast(alts.len));
                // Never enter an infinite-cost region: if the choice stream
                // picked an alternative whose minimal derivation cost is
                // maxInt (an escape-less cycle like `<doom> ::= <doom> Y`),
                // no sequence of future decisions can ever finish it — its
                // body may contain no further choice/opt/rep decision point
                // at which to bail out. Discard the pick and take the
                // minimal-cost alternative instead.
                if (nodeCost(alts[idx], self.costs) == std.math.maxInt(u32)) {
                    idx = minCostIndex(alts, self.costs);
                }
                try self.genNode(alts[idx]);
            },
            .opt => |k| {
                if (self.overBudget()) return;
                // Same guard as `.choice`: an infinite-cost child can never
                // derive a finite sentence, so descending would never
                // return. Skipping is always valid for an optional.
                if (nodeCost(k, self.costs) == std.math.maxInt(u32)) return;
                if (self.cs.next(2) == 1) try self.genNode(k);
            },
            .rep => |k| {
                // No infinite-cost guard needed here: a rep's cost equals
                // its child's, so an infinite-cost rep child makes every
                // enclosing seq/choice-alt/rule infinite-cost too — and the
                // `.choice`/`.opt` guards above plus `generate`'s start-rule
                // NoFiniteDerivation check mean such a rep is unreachable.
                try self.genNode(k);
                while (!self.overBudget() and self.cs.next(2) == 1) {
                    try self.genNode(k);
                }
            },
        }
    }
};

fn minCostIndex(alts: []const *bnf.Node, costs: *const std.StringArrayHashMapUnmanaged(u32)) u32 {
    var best_idx: u32 = 0;
    var best_cost: u32 = std.math.maxInt(u32);
    for (alts, 0..) |a, i| {
        const c = nodeCost(a, costs);
        if (c < best_cost) {
            best_cost = c;
            best_idx = @intCast(i);
        }
    }
    return best_idx;
}

pub fn generate(gpa: std.mem.Allocator, g: *const bnf.Grammar, opts: GenOptions, cs: *ChoiceSource) GenError![]u8 {
    var costs = try minCost(g, gpa);
    defer costs.deinit(gpa);

    const start_cost = costs.get(opts.start) orelse return error.UnknownRule;
    if (start_cost == std.math.maxInt(u32)) return error.NoFiniteDerivation;

    var gen = Gen{ .gpa = gpa, .g = g, .opts = opts, .cs = cs, .costs = &costs };
    errdefer gen.out.deinit(gpa);
    try gen.genRule(opts.start);
    return gen.out.toOwnedSlice(gpa);
}

test "gen: minimal derivation when choices exhausted" {
    const src =
        \\<s> ::=
        \\    BEGIN <body> END
        \\
        \\<body> ::=
        \\    NOP
        \\  | <body> NOP
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    var cs = ChoiceSource{ .bytes = .{ .data = &.{} } };
    const out = try generate(std.testing.allocator, &g, .{ .start = "s" }, &cs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("BEGIN NOP END", out);
}

test "gen: byte stream drives alternation, optional, repetition" {
    const src =
        \\<s> ::=
        \\    { A | B } [ C ] D...
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    // choice idx 1 => B; optional taken => C; rep: 1 extra then stop
    var cs = ChoiceSource{ .bytes = .{ .data = &.{ 1, 1, 1, 0 } } };
    const out = try generate(std.testing.allocator, &g, .{ .start = "s" }, &cs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("B C D D", out);
}

test "gen: overrides stop descent" {
    const src =
        \\<s> ::=
        \\    SET <identifier>
        \\
        \\<identifier> ::=
        \\    <letter>...
        \\
        \\<letter> ::=
        \\    A
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    var ov = Overrides{};
    defer ov.deinit(std.testing.allocator);
    try ov.put(std.testing.allocator, "identifier", &.{ "foo", "bar" });
    var cs = ChoiceSource{ .bytes = .{ .data = &.{1} } };
    const out = try generate(std.testing.allocator, &g, .{ .start = "s", .overrides = &ov }, &cs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("SET bar", out);
}

test "gen: unknown rule and infinite grammar errors" {
    const src =
        \\<loop> ::=
        \\    <loop> X
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    var cs = ChoiceSource{ .bytes = .{ .data = &.{} } };
    try std.testing.expectError(error.UnknownRule, generate(std.testing.allocator, &g, .{ .start = "nope" }, &cs));
    try std.testing.expectError(error.NoFiniteDerivation, generate(std.testing.allocator, &g, .{ .start = "loop" }, &cs));
}

test "gen: unit-production cycle with escape terminates (recursive alt first)" {
    // Regression: <a> ::= <b> | X ; <b> ::= <a> used to tie in nodeCost (both
    // alternatives of <a> costed 1, since .nonterm didn't charge for the
    // indirection), so minCostIndex's first-alt tie-break always picked the
    // recursive <b> alt and generation recursed a -> b -> a -> b ... until
    // stack overflow (SIGSEGV) once the byte stream was exhausted.
    const src =
        \\<a> ::=
        \\    <b>
        \\  | X
        \\
        \\<b> ::=
        \\    <a>
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    var cs = ChoiceSource{ .bytes = .{ .data = &.{} } };
    const out = try generate(std.testing.allocator, &g, .{ .start = "a" }, &cs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("X", out);
}

test "gen: longer unit-production chain with escape terminates" {
    // Same shape as above but through a 3-hop unit chain (<a> -> <b> -> <c> ->
    // <a>) to make sure the +1-per-indirection cost strictly decreases across
    // multiple hops, not just a single tied pair.
    const src =
        \\<a> ::=
        \\    <b>
        \\  | X
        \\
        \\<b> ::=
        \\    <c>
        \\
        \\<c> ::=
        \\    <a>
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    var cs = ChoiceSource{ .bytes = .{ .data = &.{} } };
    const out = try generate(std.testing.allocator, &g, .{ .start = "a" }, &cs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("X", out);
}

test "gen: byte stream cannot select an infinite-cost choice alternative" {
    // Regression: on the under-budget path, cs.next used to freely select an
    // alternative whose minimal cost is maxInt (an escape-less infinite
    // region). <doom>'s body is bare seq/nonterm with no choice/opt/rep
    // decision point, so overBudget() was never consulted again and the
    // recursion never stopped (SIGSEGV).
    const src =
        \\<s> ::=
        \\    X
        \\  | <doom>
        \\
        \\<doom> ::=
        \\    <doom> Y
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    var cs = ChoiceSource{ .bytes = .{ .data = &.{1} } };
    const out = try generate(std.testing.allocator, &g, .{ .start = "s" }, &cs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("X", out);
}

test "gen: prng source never enters infinite-cost region (seed sweep)" {
    const src =
        \\<s> ::=
        \\    X
        \\  | <doom>
        \\
        \\<doom> ::=
        \\    <doom> Y
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    var seed: u64 = 0;
    while (seed <= 20) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        var cs = ChoiceSource{ .prng = &prng };
        const out = try generate(std.testing.allocator, &g, .{ .start = "s" }, &cs);
        defer std.testing.allocator.free(out);
        // "X" is the only finite sentence in this grammar.
        try std.testing.expectEqualStrings("X", out);
    }
}

test "gen: opt wrapping an escape-less cycle is skipped" {
    const src =
        \\<s> ::=
        \\    A [ <doom> ]
        \\
        \\<doom> ::=
        \\    <doom> Y
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    // byte 1 asks to take the optional, but its child can never finish.
    var cs = ChoiceSource{ .bytes = .{ .data = &.{1} } };
    const out = try generate(std.testing.allocator, &g, .{ .start = "s" }, &cs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("A", out);
}

test "gen: override with empty pool falls through to normal expansion" {
    const src =
        \\<s> ::=
        \\    SET <identifier>
        \\
        \\<identifier> ::=
        \\    A
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    var ov = Overrides{};
    defer ov.deinit(std.testing.allocator);
    try ov.put(std.testing.allocator, "identifier", &.{});
    var cs = ChoiceSource{ .bytes = .{ .data = &.{} } };
    const out = try generate(std.testing.allocator, &g, .{ .start = "s", .overrides = &ov }, &cs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("SET A", out);
}

test "gen: char terminals emitted, impl_defined silent" {
    const src =
        \\<s> ::=
        \\    A <comma> B <weird>
        \\
        \\<comma> ::=
        \\    ,
        \\
        \\<weird> ::=
        \\    !! See the Syntax Rules.
    ;
    var g = try bnf.parse(std.testing.allocator, src);
    defer g.deinit();
    var cs = ChoiceSource{ .bytes = .{ .data = &.{} } };
    const out = try generate(std.testing.allocator, &g, .{ .start = "s" }, &cs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("A , B", out);
}
