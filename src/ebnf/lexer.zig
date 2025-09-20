const std = @import("std");
const rt = @import("../runtime/runtime.zig");
const Error = @import("ast.zig").Error;

pub const Kind = enum {
    Ident,
    Literal, // unescaped; empty "" stands for empty symbol
    Assign, // ::= or ⇐
    Pipe, // |
    LBracket, // [
    RBracket, // ]
    LBrace, // {
    RBrace, // }
    Eof,
};

pub const Tok = struct {
    kind: Kind,
    lexeme: []const u8 = "",
    value: []const u8 = "", // for Literal only: unescaped bytes (empty is empty symbol)
    span: rt.Span,
};

pub const Lexer = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    i: usize = 0,
    line: usize = 1,
    col: usize = 1,
    // When true, enables relaxed fallback behavior (added later via CLI flag). For now default false.
    permissive: bool = false,
    // Dedup map for literal value slices: value -> canonical slice (the first allocated instance).
    lit_intern: std.StringHashMap([]const u8),

    pub fn init(alloc: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .alloc = alloc, .src = src, .permissive = false, .lit_intern = std.StringHashMap([]const u8).init(alloc) };
    }

    pub fn deinit(self: *Lexer) void {
        self.lit_intern.deinit(); // values owned externally (tracked by parser), so not freed here.
    }

    fn internLiteral(self: *Lexer, owned: []const u8) ![]const u8 {
        if (owned.len == 0) return owned; // empty symbol handled specially; keep as is.
        if (self.lit_intern.get(owned)) |existing| {
            // Duplicate: free new slice and return existing canonical.
            self.alloc.free(owned);
            return existing;
        }
        try self.lit_intern.put(owned, owned);
        return owned;
    }

    fn atEnd(self: *const Lexer) bool {
        return self.i >= self.src.len;
    }
    fn cur(self: *const Lexer) u8 {
        return if (self.atEnd()) 0 else self.src[self.i];
    }

    fn adv(self: *Lexer, n: usize) void {
        var k: usize = 0;
        while (k < n and !self.atEnd()) : (k += 1) {
            if (self.src[self.i] == '\n') {
                self.line += 1;
                self.col = 1;
            } else self.col += 1;
            self.i += 1;
        }
    }

    fn matchBytes(self: *Lexer, bytes: []const u8) bool {
        if (self.i + bytes.len > self.src.len) return false;
        if (std.mem.eql(u8, self.src[self.i .. self.i + bytes.len], bytes)) {
            self.adv(bytes.len);
            return true;
        }
        return false;
    }

    fn skipWSAndComments(self: *Lexer) !void {
        while (true) {
            // whitespace
            var progressed = false;
            while (!self.atEnd() and (self.cur() == ' ' or self.cur() == '\t' or self.cur() == '\n' or self.cur() == '\r')) : (self.adv(1)) progressed = true;

            if (self.atEnd()) return;

            // // comment
            if (self.i + 1 < self.src.len and self.src[self.i] == '/' and self.src[self.i + 1] == '/') {
                progressed = true;
                self.adv(2);
                while (!self.atEnd() and self.cur() != '\n') self.adv(1);
                continue;
            }
            // /* ... */
            if (self.i + 1 < self.src.len and self.src[self.i] == '/' and self.src[self.i + 1] == '*') {
                progressed = true;
                self.adv(2);
                var depth: usize = 1;
                while (!self.atEnd() and depth > 0) {
                    if (self.i + 1 < self.src.len and self.src[self.i] == '/' and self.src[self.i + 1] == '*') {
                        depth += 1;
                        self.adv(2);
                    } else if (self.i + 1 < self.src.len and self.src[self.i] == '*' and self.src[self.i + 1] == '/') {
                        depth -= 1;
                        self.adv(2);
                    } else self.adv(1);
                }
                if (depth != 0) return Error.SyntaxError; // unterminated
                continue;
            }

            // (* ... *) nested comment style
            if (self.i + 1 < self.src.len and self.src[self.i] == '(' and self.src[self.i + 1] == '*') {
                progressed = true;
                self.adv(2);
                var depth2: usize = 1;
                while (!self.atEnd() and depth2 > 0) {
                    if (self.i + 1 < self.src.len and self.src[self.i] == '(' and self.src[self.i + 1] == '*') {
                        depth2 += 1;
                        self.adv(2);
                    } else if (self.i + 1 < self.src.len and self.src[self.i] == '*' and self.src[self.i + 1] == ')') {
                        depth2 -= 1;
                        self.adv(2);
                    } else self.adv(1);
                }
                if (depth2 != 0) return Error.SyntaxError; // unterminated
                continue;
            }

            if (!progressed) return;
        }
    }

    pub fn next(self: *Lexer) !Tok {
        while (true) { // restart loop for skippable punctuation like ';'
            try self.skipWSAndComments();
            if (self.atEnd()) return Tok{ .kind = .Eof, .span = .{ .start = self.i, .end = self.i, .line = self.line, .col = self.col } };

            const start = self.i;
            const sline = self.line;
            const scol = self.col;

            // Allow a backslash to escape a single following punctuation token used in grammars (e.g. \[ to denote literal '[' inside source EBNF file).
            if (self.cur() == '\\' and self.i + 1 < self.src.len) {
                const esc = self.src[self.i + 1];
                switch (esc) {
                    '[', ']', '{', '}', '|', ':', '(', ')', '*', '+', '?' => {
                        // Skip the backslash; treat following punctuation structurally.
                        self.adv(1); // consume only backslash; leave punctuation for normal handling below.
                    },
                    else => {},
                }
            }

            // ::=  or ⇐
            if (self.matchBytes("::=")) return Tok{ .kind = .Assign, .span = .{ .start = start, .end = self.i, .line = sline, .col = scol } };
            if (self.matchBytes("⇐")) return Tok{ .kind = .Assign, .span = .{ .start = start, .end = self.i, .line = sline, .col = scol } };

            // single char punct
            const c = self.cur();
            switch (c) {
                '|' => {
                    self.adv(1);
                    return Tok{ .kind = .Pipe, .span = .{ .start = start, .end = self.i, .line = sline, .col = scol } };
                },
                ';' => {
                    self.adv(1);
                    continue;
                },
                '.', ':', '!', '?', '(', ')', ',', '=', '+' => {
                    // These punctuation characters are treated as literal terminals in grammar.
                    // We return them as Literal tokens whose value is the single char.
                    var buf_p: std.ArrayList(u8) = .{};
                    errdefer buf_p.deinit(self.alloc);
                    try buf_p.append(self.alloc, c);
                    self.adv(1);
                    const owned_p_raw = try buf_p.toOwnedSlice(self.alloc);
                    const owned_p = try self.internLiteral(owned_p_raw);
                    return Tok{ .kind = .Literal, .lexeme = self.src[start..self.i], .value = owned_p, .span = .{ .start = start, .end = self.i, .line = sline, .col = scol } };
                },
                '[' => {
                    self.adv(1);
                    return Tok{ .kind = .LBracket, .span = .{ .start = start, .end = self.i, .line = sline, .col = scol } };
                },
                ']' => {
                    self.adv(1);
                    return Tok{ .kind = .RBracket, .span = .{ .start = start, .end = self.i, .line = sline, .col = scol } };
                },
                '{' => {
                    self.adv(1);
                    return Tok{ .kind = .LBrace, .span = .{ .start = start, .end = self.i, .line = sline, .col = scol } };
                },
                '}' => {
                    self.adv(1);
                    return Tok{ .kind = .RBrace, .span = .{ .start = start, .end = self.i, .line = sline, .col = scol } };
                },
                '\'', '"' => {
                    const quote = c;
                    self.adv(1);
                    var buf: std.ArrayList(u8) = .{};
                    errdefer buf.deinit(self.alloc);
                    while (!self.atEnd() and self.cur() != quote) {
                        const ch = self.cur();
                        if (ch == '\\') {
                            self.adv(1);
                            if (self.atEnd()) return Error.SyntaxError;
                            const esc = self.cur();
                            switch (esc) {
                                'n' => {
                                    try buf.append(self.alloc, '\n');
                                    self.adv(1);
                                },
                                'r' => {
                                    try buf.append(self.alloc, '\r');
                                    self.adv(1);
                                },
                                't' => {
                                    try buf.append(self.alloc, '\t');
                                    self.adv(1);
                                },
                                '\\' => {
                                    try buf.append(self.alloc, '\\');
                                    self.adv(1);
                                },
                                '"' => {
                                    try buf.append(self.alloc, '"');
                                    self.adv(1);
                                },
                                '\'' => {
                                    try buf.append(self.alloc, '\'');
                                    self.adv(1);
                                },
                                'x' => {
                                    self.adv(1);
                                    if (self.i + 1 >= self.src.len) return Error.SyntaxError;
                                    const h1 = self.src[self.i];
                                    const h2 = self.src[self.i + 1];
                                    const v1 = hex(h1) orelse return Error.SyntaxError;
                                    const v2 = hex(h2) orelse return Error.SyntaxError;
                                    try buf.append(self.alloc, @as(u8, v1 * 16 + v2));
                                    self.adv(2);
                                },
                                else => return Error.SyntaxError,
                            }
                        } else {
                            try buf.append(self.alloc, ch);
                            self.adv(1);
                        }
                    }
                    if (self.atEnd() or self.cur() != quote) return Error.SyntaxError;
                    self.adv(1);
                    const owned_raw = try buf.toOwnedSlice(self.alloc);
                    const owned = try self.internLiteral(owned_raw);
                    return Tok{
                        .kind = .Literal,
                        .lexeme = self.src[start..self.i],
                        .value = owned,
                        .span = .{ .start = start, .end = self.i, .line = sline, .col = scol },
                    };
                },
                else => {},
            }

            // ident: [A-Za-z_][A-Za-z0-9_]* or a single punctuation escaped with backslash in source grammar (e.g. \\[ used as literal token alias)
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
                self.adv(1);
                while (!self.atEnd()) {
                    const d = self.cur();
                    if ((d >= 'a' and d <= 'z') or (d >= 'A' and d <= 'Z') or (d >= '0' and d <= '9') or d == '_') self.adv(1) else break;
                }
                return Tok{
                    .kind = .Ident,
                    .lexeme = self.src[start..self.i],
                    .span = .{ .start = start, .end = self.i, .line = sline, .col = scol },
                };
            }
            // Backslash escape handled above; any remaining standalone backslash will fall through to syntax error below.

            if (self.permissive) {
                // In permissive mode only: attempt similar fallback for legacy behavior.
                if (self.cur() >= 'A' and self.cur() <= 'Z') {
                    self.adv(1);
                    while (!self.atEnd()) : (self.adv(1)) {
                        const ch = self.cur();
                        if (!(ch >= 'A' and ch <= 'Z')) break;
                    }
                    return Tok{ .kind = .Ident, .lexeme = self.src[start..self.i], .span = .{ .start = start, .end = self.i, .line = sline, .col = scol } };
                }
                if (!self.atEnd() and self.cur() != 0) {
                    var buf2: std.ArrayList(u8) = .{};
                    errdefer buf2.deinit(self.alloc);
                    try buf2.append(self.alloc, self.cur());
                    self.adv(1);
                    const owned2_raw = try buf2.toOwnedSlice(self.alloc);
                    const owned2 = try self.internLiteral(owned2_raw);
                    return Tok{ .kind = .Literal, .lexeme = self.src[start..self.i], .value = owned2, .span = .{ .start = start, .end = self.i, .line = sline, .col = scol } };
                }
            }
            // Strict mode: unknown char => syntax error.
            return Error.SyntaxError;
        }
    }
};

fn hex(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return 10 + c - 'a';
    if (c >= 'A' and c <= 'F') return 10 + c - 'A';
    return null;
}
