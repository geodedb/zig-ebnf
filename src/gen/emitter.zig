const std = @import("std");
const ast = @import("../ebnf/ast.zig");
const rd = @import("rd_emitter.zig");
const stub_backend = @import("stub_emitter.zig");

pub const GenBackend = enum { RecursiveDescent, Stub };
pub const GenOptions = struct {
    backend: GenBackend = .RecursiveDescent,
    module_name: []const u8 = "generated",
    start_rule: []const u8,
    emit_cli_demo: bool = false,
};

pub const GeneratedFile = struct { path: []const u8, contents: []const u8 };
pub const Generated = struct {
    files: []const GeneratedFile,
    pub fn deinit(self: *Generated, alloc: std.mem.Allocator) void {
        for (self.files) |f| {
            alloc.free(f.path);
            alloc.free(f.contents);
        }
        alloc.free(self.files);
        self.* = undefined;
    }
};

pub fn emit(alloc: std.mem.Allocator, grammar: *const ast.AST, opts: GenOptions) !Generated {
    try grammar.ensureNoDuplicates();
    var has_stub = false;
    for (grammar.rules) |r| {
        if (r.span.line == 0) {
            has_stub = true;
            break;
        }
    }
    if (!has_stub) try grammar.ensureDefinedSymbols();
    try grammar.checkReachability(opts.start_rule);
    try grammar.checkEmptyRepetition();
    try grammar.checkLeftRecursion();

    // Gather synthetic stubs for header comment
    var stub_count: usize = 0;
    for (grammar.rules) |r| {
        if (r.span.line == 0) stub_count += 1;
    }

    // Shared stub header (used by stub or RD backend)
    var header_buf: std.ArrayList(u8) = .{};
    defer header_buf.deinit(alloc);
    const hw = header_buf.writer(alloc);
    try hw.writeAll("// Generated parser module (zig-ebnfgen)\n");
    if (stub_count > 0) {
        try hw.print("// NOTE: {d} synthetic stub rule(s) inserted (permissive mode).\n// synthetic stub rule list: ", .{stub_count});
        var first = true;
        for (grammar.rules) |r| {
            if (r.span.line == 0) {
                if (!first) try hw.writeAll(", ") else first = false;
                try hw.writeAll(r.name);
            }
        }
        try hw.writeAll("\n");
    }
    const header = try header_buf.toOwnedSlice(alloc);
    var mod_code: []u8 = undefined;
    var backend_name: []const u8 = undefined;
    switch (opts.backend) {
        .RecursiveDescent => {
            backend_name = "RecursiveDescent";
            mod_code = try rd.emitRecursiveDescent(alloc, grammar, opts.start_rule, header);
        },
        .Stub => {
            backend_name = "Stub";
            mod_code = try stub_backend.emitStub(alloc, grammar, opts.start_rule, header);
        },
    }
    // header no longer needed after copy into module code
    alloc.free(header);
    const mod_path = try std.fmt.allocPrint(alloc, "{s}/mod.zig", .{opts.module_name});
    var files: std.ArrayList(GeneratedFile) = .{};
    try files.append(alloc, .{ .path = mod_path, .contents = mod_code });
    const readme = try std.fmt.allocPrint(
        alloc,
        "# {s}\n\nBackend: {s}\n\nSynthetic stub rules: {d}\n",
        .{ opts.module_name, backend_name, stub_count },
    );
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.generated.md", .{opts.module_name});
    try files.append(alloc, .{ .path = readme_path, .contents = readme });
    if (opts.emit_cli_demo and opts.backend == .RecursiveDescent) {
        const demo_path = try std.fmt.allocPrint(alloc, "{s}/cli_demo.zig", .{opts.module_name});
        var demo_buf: std.ArrayList(u8) = .{};
        defer demo_buf.deinit(alloc);
        try demo_buf.appendSlice(alloc, "const std = @import(\"std\");\nconst gen = @import(\"mod.zig\");\npub fn main() !void {\n    if (std.os.argv.len < 2) { std.debug.print(\"usage: <prog> <input>\\n\", .{}); return; }\n    const input = std.mem.span(@ptrCast([*:0]const u8, std.os.argv[1]));\n    gen.recognize_");
        try demo_buf.appendSlice(alloc, opts.start_rule);
        try demo_buf.appendSlice(alloc, "(input) catch |e| switch (e) { error.Unexpected => std.debug.print(\"REJECT unexpected\\n\", .{}), error.Trailing => std.debug.print(\"REJECT trailing\\n\", .{}), };\n}\n");
        const demo_code = try demo_buf.toOwnedSlice(alloc);
        try files.append(alloc, .{ .path = demo_path, .contents = demo_code });
    }
    return Generated{ .files = try files.toOwnedSlice(alloc) };
}
