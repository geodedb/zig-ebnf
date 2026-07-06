const std = @import("std");

pub const gen = @import("gen.zig");

pub const Node = union(enum) {
    seq: []const *Node,
    choice: []const *Node,
    opt: *Node,
    group: *Node,
    rep: *Node,
    keyword: []const u8,
    char: u8,
    nonterm: []const u8,
    impl_defined,
    /// A raw multi-character symbol literal that isn't an ALL-CAPS reserved
    /// word (e.g. the ISO/IEC 39075 GQL artifact's `::=`, `<-[`, `<>`, `||`).
    /// See `rawSymbolBody` for how these are detected during parsing.
    literal: []const u8,
};

pub const ParseError = error{ SyntaxError, DuplicateRule, OutOfMemory };

pub const Grammar = struct {
    arena: std.heap.ArenaAllocator,
    rules: std.StringArrayHashMapUnmanaged(*Node),

    pub fn deinit(self: *Grammar) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn find(self: *const Grammar, name: []const u8) ?*Node {
        return self.rules.get(name);
    }
    pub fn ruleCount(self: *const Grammar) usize {
        return self.rules.count();
    }

    pub const ValidateError = error{ UndefinedNonterminal, OutOfMemory };

    /// Returns error.UndefinedNonterminal iff `undefinedNonterminals` is non-empty.
    pub fn validate(self: *const Grammar, gpa: std.mem.Allocator) ValidateError!void {
        const undef = try self.undefinedNonterminals(gpa);
        defer gpa.free(undef);
        if (undef.len != 0) return error.UndefinedNonterminal;
    }

    /// Names referenced via `.nonterm` in any rule body but not present as a rule
    /// name. Caller frees the returned slice with `gpa`; the strings themselves
    /// point into the grammar's arena.
    pub fn undefinedNonterminals(self: *const Grammar, gpa: std.mem.Allocator) ![]const []const u8 {
        var seen: std.StringArrayHashMapUnmanaged(void) = .{};
        defer seen.deinit(gpa);
        for (self.rules.values()) |node| {
            try collectNonterms(node, gpa, &seen);
        }
        var undef: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer undef.deinit(gpa);
        for (seen.keys()) |name| {
            if (!self.rules.contains(name)) try undef.append(gpa, name);
        }
        return undef.toOwnedSlice(gpa);
    }

    /// Every `.keyword` terminal referenced in any rule body, deduplicated.
    /// Caller deinits the returned map with the same `gpa`; keys point into the
    /// grammar's arena.
    pub fn keywords(self: *const Grammar, gpa: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(void) {
        var kw: std.StringArrayHashMapUnmanaged(void) = .{};
        errdefer kw.deinit(gpa);
        for (self.rules.values()) |node| {
            try collectKeywords(node, gpa, &kw);
        }
        return kw;
    }

    /// Copies every rule of `other` into `self`, deep-copying nodes into self's
    /// arena so `self` remains valid after `other` is deinit'd. Overwrites rules
    /// with the same name.
    pub fn mergeFrom(self: *Grammar, gpa: std.mem.Allocator, other: *const Grammar) !void {
        const a = self.arena.allocator();
        var it = other.rules.iterator();
        while (it.next()) |entry| {
            const name = try a.dupe(u8, entry.key_ptr.*);
            const node = try deepCopy(a, entry.value_ptr.*);
            const gop = try self.rules.getOrPut(a, name);
            gop.value_ptr.* = node;
        }
        _ = gpa; // unused: all allocations go through self's arena so merged rules
        // outlive `other`'s own arena/allocator.
    }
};

fn collectNonterms(n: *const Node, gpa: std.mem.Allocator, seen: *std.StringArrayHashMapUnmanaged(void)) std.mem.Allocator.Error!void {
    switch (n.*) {
        .nonterm => |name| try seen.put(gpa, name, {}),
        .seq, .choice => |kids| for (kids) |k| try collectNonterms(k, gpa, seen),
        .opt, .group, .rep => |k| try collectNonterms(k, gpa, seen),
        else => {},
    }
}

fn collectKeywords(n: *const Node, gpa: std.mem.Allocator, kw: *std.StringArrayHashMapUnmanaged(void)) std.mem.Allocator.Error!void {
    switch (n.*) {
        .keyword => |name| try kw.put(gpa, name, {}),
        .seq, .choice => |kids| for (kids) |k| try collectKeywords(k, gpa, kw),
        .opt, .group, .rep => |k| try collectKeywords(k, gpa, kw),
        else => {},
    }
}

fn deepCopy(a: std.mem.Allocator, n: *const Node) std.mem.Allocator.Error!*Node {
    const copy = try a.create(Node);
    switch (n.*) {
        .seq => |kids| {
            const out = try a.alloc(*Node, kids.len);
            for (kids, 0..) |k, i| out[i] = try deepCopy(a, k);
            copy.* = .{ .seq = out };
        },
        .choice => |kids| {
            const out = try a.alloc(*Node, kids.len);
            for (kids, 0..) |k, i| out[i] = try deepCopy(a, k);
            copy.* = .{ .choice = out };
        },
        .opt => |k| copy.* = .{ .opt = try deepCopy(a, k) },
        .group => |k| copy.* = .{ .group = try deepCopy(a, k) },
        .rep => |k| copy.* = .{ .rep = try deepCopy(a, k) },
        .keyword => |s| copy.* = .{ .keyword = try a.dupe(u8, s) },
        .char => |c| copy.* = .{ .char = c },
        .nonterm => |s| copy.* = .{ .nonterm = try a.dupe(u8, s) },
        .impl_defined => copy.* = .impl_defined,
        .literal => |s| copy.* = .{ .literal = try a.dupe(u8, s) },
    }
    return copy;
}

pub fn parse(gpa: std.mem.Allocator, src: []const u8) ParseError!Grammar {
    var g = Grammar{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .rules = .{},
    };
    errdefer g.deinit();
    const a = g.arena.allocator();

    // 1. Split into (name, raw body) productions at column-0 `<...> ::=` headers.
    var headers: std.ArrayListUnmanaged(struct { name: []const u8, body_start: usize }) = .{};
    defer headers.deinit(gpa);
    var it = std.mem.splitScalar(u8, src, '\n');
    var offset: usize = 0;
    while (it.next()) |line| : (offset += line.len + 1) {
        if (headerName(line)) |name| {
            try headers.append(gpa, .{ .name = name, .body_start = offset + line.len + 1 });
        }
    }
    if (headers.items.len == 0) return error.SyntaxError;

    // Collect every production name up front (independent of insertion order
    // into `g.rules`) so body-parsing can distinguish a genuine nonterminal
    // alias like `<left angle bracket>` from a raw multi-char symbol literal
    // that merely starts with `<`, e.g. `<-[` or `<>` (see `rawSymbolBody`).
    var names: NameSet = .{};
    defer names.deinit(gpa);
    for (headers.items) |h| {
        try names.put(gpa, h.name, {});
    }

    for (headers.items, 0..) |h, i| {
        const body_end = if (i + 1 < headers.items.len) blk: {
            // header line begins at body_start of previous minus its own length —
            // recompute: body of rule i ends where header line of rule i+1 begins.
            const next_start = headers.items[i + 1].body_start;
            // back up over the header line itself
            var j = next_start - 1; // index of '\n' terminating header line
            while (j > 0 and src[j - 1] != '\n') j -= 1;
            break :blk j;
        } else src.len;
        const body = src[@min(h.body_start, src.len)..body_end];
        const name = try a.dupe(u8, h.name);
        const node = try parseBody(a, body, &names);
        const gop = try g.rules.getOrPut(a, name);
        if (gop.found_existing) return error.DuplicateRule;
        gop.value_ptr.* = node;
    }
    return g;
}

const NameSet = std.StringArrayHashMapUnmanaged(void);

/// Returns the production name if `line` is a column-0 `<name> ::=` header.
fn headerName(line: []const u8) ?[]const u8 {
    if (line.len < 6 or line[0] != '<') return null;
    const close = std.mem.indexOfScalar(u8, line, '>') orelse return null;
    const rest = std.mem.trim(u8, line[close + 1 ..], " \t\r");
    if (!std.mem.eql(u8, rest, "::=")) return null;
    return line[1..close];
}

fn parseBody(a: std.mem.Allocator, body: []const u8, names: *const NameSet) ParseError!*Node {
    // Single-char special case: strip newlines and a leading 4-space indent per
    // line; if exactly one char remains, it's a char-literal terminal.
    if (singleCharBody(body)) |c| {
        const n = try a.create(Node);
        n.* = .{ .char = c };
        return n;
    }
    // Raw multi-char symbol literal (e.g. `::=`... no — `::`, `<-[`, `<>`,
    // `||`): a whole body reducing to one non-blank line built entirely from
    // punctuation, that isn't itself a `<known rule name>` alias.
    if (rawSymbolBody(body, names)) |s| {
        const n = try a.create(Node);
        n.* = .{ .literal = try a.dupe(u8, s) };
        return n;
    }
    var p = BodyParser{ .a = a, .src = body, .i = 0 };
    const node = try p.parseChoice();
    p.skipWs();
    if (p.i != p.src.len) return error.SyntaxError;
    return node;
}

fn singleCharBody(body: []const u8) ?u8 {
    var found: ?u8 = null;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        // strip up to 4 leading spaces of indent
        var k: usize = 0;
        while (k < 4 and k < line.len and line[k] == ' ') k += 1;
        const content = line[k..];
        if (content.len == 0) continue;
        if (content.len == 1) {
            if (found != null) return null;
            found = content[0];
        } else if (std.mem.eql(u8, content, "\xc2\xa0")) {
            // The real ISO/IEC 39075 GQL artifact renders `<space> ::=` with
            // a UTF-8 NO-BREAK SPACE (U+00A0, bytes C2 A0) rather than a
            // literal ASCII space — collapses to the same char literal.
            if (found != null) return null;
            found = ' ';
        } else {
            // a line of trailing spaces only (e.g. the <space> rule) collapses
            const trimmed = std.mem.trimRight(u8, content, " ");
            if (trimmed.len == 0) {
                if (found != null) return null;
                found = ' ';
            } else return null;
        }
    }
    // Only treat non-alphanumeric as char literal; a single CAPS letter is a keyword.
    if (found) |c| if (!std.ascii.isAlphanumeric(c)) return c;
    return null;
}

/// Detects a whole rule body that is a raw multi-character symbol/punctuation
/// literal — the ISO/IEC 39075 GQL artifact spells operator and delimiter
/// tokens this way, e.g. `<double colon> ::= ::`, `<left arrow bracket> ::=
/// <-[`, `<not equals operator> ::= <>`, `<concatenation operator> ::= ||`.
///
/// These bodies collapse (after stripping the 4-space indent) to exactly one
/// non-blank line built entirely from punctuation characters. The only
/// ambiguity is a line of the form `<name>`, which is indistinguishable by
/// shape alone from a genuine nonterminal alias (e.g. `<less than operator>
/// ::= <left angle bracket>`); `names` (every production name collected
/// up front in `parse`) resolves it — if `name` is a real rule, defer to the
/// structural parser instead.
fn rawSymbolBody(body: []const u8, names: *const NameSet) ?[]const u8 {
    var content: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        var k: usize = 0;
        while (k < 4 and k < line.len and line[k] == ' ') k += 1;
        const c = std.mem.trimRight(u8, line[k..], " ");
        if (c.len == 0) continue;
        if (content != null) return null; // more than one non-blank line: not this shape
        content = c;
    }
    const c = content orelse return null;
    if (c.len < 2) return null; // single-char bodies are handled by singleCharBody
    if (c[0] == '<' and c[c.len - 1] == '>') {
        if (names.contains(c[1 .. c.len - 1])) return null; // genuine nonterm alias
    }
    for (c) |ch| {
        switch (ch) {
            '<', '>', '[', ']', '{', '}', '(', ')', '-', '~', '=', '/', '\\', ':', ';', ',', '.', '!', '?', '\'', '"', '`', '@', '#', '$', '%', '^', '&', '*', '+', '_', '|' => {},
            else => return null, // contains a letter/digit/space: not a bare symbol run
        }
    }
    return c;
}

const BodyParser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    i: usize,

    fn skipWs(self: *BodyParser) void {
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn parseChoice(self: *BodyParser) ParseError!*Node {
        var alts: std.ArrayListUnmanaged(*Node) = .{};
        self.skipWs();
        // A handful of ISO/IEC 39075 GQL artifact choice bodies have a blank
        // line before the first `| ALTERNATIVE` branch (e.g. `<pre-reserved
        // word>`) — a stray leading `|` with nothing in front of it. Treat
        // that vacuous first alternative as simply absent instead of a
        // syntax error; the loop below parses the branches that follow.
        if (self.i >= self.src.len or self.src[self.i] != '|') {
            try alts.append(self.a, try self.parseSeq());
        }
        while (true) {
            self.skipWs();
            if (self.i < self.src.len and self.src[self.i] == '|') {
                self.i += 1;
                try alts.append(self.a, try self.parseSeq());
            } else break;
        }
        if (alts.items.len == 0) return error.SyntaxError; // body was empty or just whitespace/`|`
        if (alts.items.len == 1) return alts.items[0];
        const n = try self.a.create(Node);
        n.* = .{ .choice = try alts.toOwnedSlice(self.a) };
        return n;
    }

    fn parseSeq(self: *BodyParser) ParseError!*Node {
        var elems: std.ArrayListUnmanaged(*Node) = .{};
        while (try self.parseElement()) |e| try elems.append(self.a, e);
        if (elems.items.len == 0) return error.SyntaxError;
        if (elems.items.len == 1) return elems.items[0];
        const n = try self.a.create(Node);
        n.* = .{ .seq = try elems.toOwnedSlice(self.a) };
        return n;
    }

    /// One element with optional postfix `...`; null at choice/close boundaries.
    fn parseElement(self: *BodyParser) ParseError!?*Node {
        self.skipWs();
        if (self.i >= self.src.len) return null;
        const c = self.src[self.i];
        var node: *Node = undefined;
        switch (c) {
            '|', ']', '}' => return null,
            '<' => {
                // Whole-body raw symbol literals starting with `<` (e.g.
                // `<-[`, `<>`) are intercepted before this parser ever runs
                // (see `rawSymbolBody`), so a `<` reaching here always opens
                // a genuine `<nonterm>` reference — including intentionally
                // undefined ones a caller wants `Grammar.validate` to catch.
                const close = std.mem.indexOfScalarPos(u8, self.src, self.i, '>') orelse
                    return error.SyntaxError;
                node = try self.mk(.{ .nonterm = try self.a.dupe(u8, self.src[self.i + 1 .. close]) });
                self.i = close + 1;
            },
            '[' => {
                self.i += 1;
                const inner = try self.parseChoice();
                try self.expect(']');
                node = try self.mk(.{ .opt = inner });
            },
            '{' => {
                self.i += 1;
                const inner = try self.parseChoice();
                try self.expect('}');
                node = try self.mk(.{ .group = inner });
            },
            '!' => {
                if (self.i + 1 < self.src.len and self.src[self.i + 1] == '!') {
                    // consume to end of line
                    const nl = std.mem.indexOfScalarPos(u8, self.src, self.i, '\n') orelse self.src.len;
                    self.i = nl;
                    node = try self.mk(.impl_defined);
                } else return error.SyntaxError;
            },
            'A'...'Z' => {
                var j = self.i;
                while (j < self.src.len) : (j += 1) {
                    switch (self.src[j]) {
                        'A'...'Z', '0'...'9', '_' => {},
                        else => break,
                    }
                }
                node = try self.mk(.{ .keyword = try self.a.dupe(u8, self.src[self.i..j]) });
                self.i = j;
            },
            // The GQL character-class rules (e.g. `<simple Latin
            // lower-case letter> ::= a | b | ... | z`, `<binary digit> ::=
            // 0 | 1`) spell each alternative as one bare lower-case letter
            // or digit — distinct from the ALL-CAPS `.keyword` reserved
            // words above, so these become single-char `.char` literals.
            'a'...'z', '0'...'9' => {
                node = try self.mk(.{ .char = c });
                self.i += 1;
            },
            '.' => {
                // A bare `...` with no preceding element is a syntax error;
                // postfix handling below consumes it when attached.
                return error.SyntaxError;
            },
            else => return error.SyntaxError,
        }
        // postfix `...` (no whitespace requirement between element and dots)
        self.skipWs();
        if (self.i + 2 < self.src.len + 1 and self.i + 3 <= self.src.len and
            std.mem.eql(u8, self.src[self.i .. self.i + 3], "..."))
        {
            self.i += 3;
            node = try self.mk(.{ .rep = node });
        }
        return node;
    }

    fn expect(self: *BodyParser, c: u8) ParseError!void {
        self.skipWs();
        if (self.i >= self.src.len or self.src[self.i] != c) return error.SyntaxError;
        self.i += 1;
    }

    fn mk(self: *BodyParser, v: Node) ParseError!*Node {
        const n = try self.a.create(Node);
        n.* = v;
        return n;
    }
};

test "bnf: parses simple production with alternation and optional" {
    const src =
        \\Header banner to be skipped.
        \\
        \\<end transaction command> ::=
        \\    <rollback command>
        \\  | <commit command>
        \\
        \\<rollback command> ::=
        \\    ROLLBACK [ WORK ]
        \\
        \\<commit command> ::=
        \\    COMMIT
    ;
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 3), g.ruleCount());
    const etc = g.find("end transaction command").?;
    try std.testing.expect(etc.* == .choice);
    try std.testing.expectEqual(@as(usize, 2), etc.choice.len);
    const rb = g.find("rollback command").?;
    // ROLLBACK [ WORK ]  => seq(keyword, opt(keyword))
    try std.testing.expect(rb.* == .seq);
    try std.testing.expect(rb.seq[0].* == .keyword);
    try std.testing.expectEqualStrings("ROLLBACK", rb.seq[0].keyword);
    try std.testing.expect(rb.seq[1].* == .opt);
}

test "bnf: grouping, repetition, nested" {
    const src =
        \\<list> ::=
        \\    <item> [ { <comma> <item> }... ]
        \\
        \\<item> ::=
        \\    X
        \\
        \\<comma> ::=
        \\    ,
    ;
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    const list = g.find("list").?;
    try std.testing.expect(list.* == .seq);
    const tail = list.seq[1]; // [ {..}... ]
    try std.testing.expect(tail.* == .opt);
    try std.testing.expect(tail.opt.* == .rep);
    try std.testing.expect(tail.opt.rep.* == .group);
    const comma = g.find("comma").?;
    try std.testing.expect(comma.* == .char);
    try std.testing.expectEqual(@as(u8, ','), comma.char);
}

test "bnf: single-char productions incl structural chars and space" {
    const src =
        \\<vertical bar> ::=
        \\    |
        \\
        \\<left bracket> ::=
        \\    [
        \\
        \\<space> ::=
        \\     
    ;
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    try std.testing.expectEqual(@as(u8, '|'), g.find("vertical bar").?.char);
    try std.testing.expectEqual(@as(u8, '['), g.find("left bracket").?.char);
    try std.testing.expectEqual(@as(u8, ' '), g.find("space").?.char);
}

test "bnf: implementation-defined alternative and inline marker" {
    const src =
        \\<mode> ::=
        \\    !! See the Syntax Rules.
        \\
        \\<esc> ::=
        \\    <double single quote>!! See the Syntax Rules.
        \\  | A
    ;
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    try std.testing.expect(g.find("mode").?.* == .impl_defined);
    const esc = g.find("esc").?;
    try std.testing.expect(esc.* == .choice);
    try std.testing.expect(esc.choice[0].* == .seq); // nonterm + impl_defined
}

test "bnf: blank line inside body does not split production" {
    const src =
        \\<words> ::=
        \\    ASIN
        \\    
        \\  | AT
    ;
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.ruleCount());
    try std.testing.expectEqual(@as(usize, 2), g.find("words").?.choice.len);
}

test "bnf: duplicate rule rejected" {
    const src =
        \\<a> ::=
        \\    X
        \\
        \\<a> ::=
        \\    Y
    ;
    try std.testing.expectError(error.DuplicateRule, parse(std.testing.allocator, src));
}

test "bnf: undefined nonterminal detected" {
    const src =
        \\<a> ::=
        \\    <missing> X
    ;
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    try std.testing.expectError(error.UndefinedNonterminal, g.validate(std.testing.allocator));
    const undef = try g.undefinedNonterminals(std.testing.allocator);
    defer std.testing.allocator.free(undef);
    try std.testing.expectEqual(@as(usize, 1), undef.len);
    try std.testing.expectEqualStrings("missing", undef[0]);
}

test "bnf: keywords collects all CAPS terminals once" {
    const src =
        \\<a> ::=
        \\    START TRANSACTION [ READ { ONLY | WRITE } ]
        \\
        \\<b> ::=
        \\    COMMIT
        \\  | START
    ;
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    var kw = try g.keywords(std.testing.allocator);
    defer kw.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), kw.count());
    try std.testing.expect(kw.contains("TRANSACTION"));
    try std.testing.expect(kw.contains("ONLY"));
}

test "bnf: mergeFrom adds and overrides rules" {
    const base_src =
        \\<a> ::=
        \\    X
        \\
        \\<b> ::=
        \\    Y
    ;
    const ext_src =
        \\<b> ::=
        \\    Y
        \\  | Z <c>
        \\
        \\<c> ::=
        \\    W
    ;
    var base = try parse(std.testing.allocator, base_src);
    defer base.deinit();
    var ext = try parse(std.testing.allocator, ext_src);
    defer ext.deinit();
    try base.mergeFrom(std.testing.allocator, &ext);
    ext.deinit();
    ext = try parse(std.testing.allocator, ext_src); // prove deep copy: base survives ext death
    try std.testing.expectEqual(@as(usize, 3), base.ruleCount());
    try std.testing.expect(base.find("b").?.* == .choice);
    try base.validate(std.testing.allocator);
}

test "bnf: raw multi-char symbol literal bodies parse as .literal" {
    // Regression: the real ISO/IEC 39075 GQL artifact spells punctuation
    // terminals as whole-body symbol runs like `::`, `<-[`, `<>`, `||` —
    // these used to hit the `<` nonterm-reference path (misparsing or
    // erroring) or the generic-char `else` branch (SyntaxError).
    const src =
        \\<double colon> ::=
        \\    ::
        \\
        \\<left arrow bracket> ::=
        \\    <-[
        \\
        \\<not equals operator> ::=
        \\    <>
        \\
        \\<concatenation operator> ::=
        \\    ||
        \\
        \\<less than operator> ::=
        \\    <left angle bracket>
        \\
        \\<left angle bracket> ::=
        \\    <
    ;
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    try std.testing.expectEqualStrings("::", g.find("double colon").?.literal);
    try std.testing.expectEqualStrings("<-[", g.find("left arrow bracket").?.literal);
    try std.testing.expectEqualStrings("<>", g.find("not equals operator").?.literal);
    try std.testing.expectEqualStrings("||", g.find("concatenation operator").?.literal);
    // A genuine nonterm alias whose target name happens to exist must still
    // be a `.nonterm`, not misclassified as a raw literal.
    const lto = g.find("less than operator").?;
    try std.testing.expect(lto.* == .nonterm);
    try std.testing.expectEqualStrings("left angle bracket", lto.nonterm);
    try g.validate(std.testing.allocator);
}

test "bnf: single lower-case letter and digit alternatives become char literals" {
    const src =
        \\<simple Latin lower-case letter> ::=
        \\    a
        \\  | b
        \\  | c
        \\
        \\<binary digit> ::=
        \\    0
        \\  | 1
    ;
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    const letters = g.find("simple Latin lower-case letter").?;
    try std.testing.expect(letters.* == .choice);
    try std.testing.expectEqual(@as(u8, 'a'), letters.choice[0].char);
    try std.testing.expectEqual(@as(u8, 'b'), letters.choice[1].char);
    const digits = g.find("binary digit").?;
    try std.testing.expectEqual(@as(u8, '0'), digits.choice[0].char);
    try std.testing.expectEqual(@as(u8, '1'), digits.choice[1].char);
}

test "bnf: leading blank line before first choice branch is tolerated" {
    // Regression: <pre-reserved word> in the real artifact has a blank line
    // right after `::=`, so the first visible branch is `| ABSTRACT` with no
    // preceding alternative — previously a SyntaxError (empty first alt).
    const src =
        \\<pre-reserved word> ::=
        \\
        \\  | ABSTRACT
        \\  | AGGREGATE
    ;
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    const prw = g.find("pre-reserved word").?;
    try std.testing.expect(prw.* == .choice);
    try std.testing.expectEqual(@as(usize, 2), prw.choice.len);
    try std.testing.expectEqualStrings("ABSTRACT", prw.choice[0].keyword);
    try std.testing.expectEqualStrings("AGGREGATE", prw.choice[1].keyword);
}

test "bnf: NBSP-rendered <space> rule collapses to a space char literal" {
    // Regression: the real artifact renders `<space> ::=` with a UTF-8
    // NO-BREAK SPACE (U+00A0 / bytes C2 A0) instead of a literal ASCII space.
    const src = "<space> ::=\n    \xc2\xa0\n";
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    try std.testing.expectEqual(@as(u8, ' '), g.find("space").?.char);
}

test "bnf: parses the full ISO/IEC 39075 GQL artifact" {
    const src = @embedFile("iso_gql_bnf");
    var g = try parse(std.testing.allocator, src);
    defer g.deinit();
    try std.testing.expect(g.ruleCount() >= 800);
    try g.validate(std.testing.allocator);
    var kw = try g.keywords(std.testing.allocator);
    defer kw.deinit(std.testing.allocator);
    try std.testing.expect(kw.count() >= 300);
    try std.testing.expect(g.find("GQL-program") != null);
    // deterministic generation from the real grammar must terminate
    var prng = std.Random.DefaultPrng.init(42);
    var cs = gen.ChoiceSource{ .prng = &prng };
    const out = try gen.generate(std.testing.allocator, &g, .{ .start = "GQL-program", .max_depth = 40 }, &cs);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
}

test {
    _ = gen;
}
