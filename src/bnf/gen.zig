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
/// costs (undefined references — which validated grammars won't have — cost
/// 1). Rules unreachable from a finite derivation settle at
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
        .nonterm => |name| costs.get(name) orelse 1,
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
                const idx = if (self.overBudget())
                    minCostIndex(alts, self.costs)
                else
                    self.cs.next(@intCast(alts.len));
                try self.genNode(alts[idx]);
            },
            .opt => |k| {
                if (self.overBudget()) return;
                if (self.cs.next(2) == 1) try self.genNode(k);
            },
            .rep => |k| {
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
