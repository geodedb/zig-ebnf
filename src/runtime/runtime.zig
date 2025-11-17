const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,
    line: usize,
    col: usize,
};

pub fn lineColOf(input: []const u8, index: usize) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;
    var i: usize = 0;
    while (i < index and i < input.len) : (i += 1) {
        if (input[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

pub fn fmtError(alloc: std.mem.Allocator, code: []const u8, idx: usize, reason: []const u8) ![]u8 {
    const lc = lineColOf(code, idx);
    return std.fmt.allocPrint(alloc, "{s} @{d}:{d}", .{ reason, lc.line, lc.col });
}

/// A simple byte cursor with save/restore and bounds checks.
pub const Cursor = struct {
    buf: []const u8,
    idx: usize = 0,

    pub fn atEnd(self: *const Cursor) bool {
        return self.idx >= self.buf.len;
    }
    pub fn peek(self: *const Cursor) u8 {
        return if (self.atEnd()) 0 else self.buf[self.idx];
    }
    pub fn save(self: *const Cursor) usize {
        return self.idx;
    }
    pub fn restore(self: *Cursor, mark: usize) void {
        self.idx = mark;
    }
    pub fn advance(self: *Cursor, n: usize) void {
        self.idx = @min(self.buf.len, self.idx + n);
    }
};

/// Utility: check path stays under out_dir/<module-name>/, returning sanitized join.
pub fn sanitizeJoin(alloc: std.mem.Allocator, out_dir: []const u8, module_name: []const u8, out: *std.ArrayList(u8)) ![]u8 {
    // Only [A-Za-z0-9_]
    var ok = true;
    for (module_name) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) {
            ok = false;
            break;
        }
    }
    if (!ok or module_name.len == 0) return error.InvalidModuleName;

    try out.appendSlice(out_dir);
    if (!std.fs.path.isSep(out_dir[out_dir.len - 1])) try out.append(std.fs.path.sep);
    try out.appendSlice(module_name);
    return out.items;
}
