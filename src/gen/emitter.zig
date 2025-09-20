const std = @import("std");
const ast = @import("../ebnf/ast.zig");

pub const GenBackend = enum { RecursiveDescent };
pub const GenOptions = struct {
    backend: GenBackend = .RecursiveDescent,
    module_name: []const u8 = "generated",
    start_rule: []const u8, // required
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
    // Keep validations intact so tests still exercise them.
    try grammar.ensureNoDuplicates();
    try grammar.ensureDefinedSymbols();
    try grammar.checkReachability(opts.start_rule);
    try grammar.checkEmptyRepetition();
    try grammar.checkLeftRecursion();

    var code_builder: std.ArrayList(u8) = .{};
    defer code_builder.deinit(alloc);
    const w = code_builder.writer(alloc);
    try w.writeAll("// Simplified generated module (stub).\nconst std = @import(\"std\");\n\n");
    try w.writeAll("pub const RecognizerError = error{Unexpected, Trailing};\n\n");
    try w.writeAll("// Start rule: ");
    try w.writeAll(opts.start_rule);
    try w.writeAll("\n");
    try w.writeAll("pub fn recognize_");
    try w.writeAll(opts.start_rule);
    try w.writeAll("(input: []const u8) !void { _ = input; }\n");

    const mod_path = try std.fmt.allocPrint(alloc, "{s}/mod.zig", .{opts.module_name});
    const mod_code = try code_builder.toOwnedSlice(alloc);
    var files: std.ArrayList(GeneratedFile) = .{};
    try files.append(alloc, .{ .path = mod_path, .contents = mod_code });
    const gen_readme = try std.fmt.allocPrint(alloc, "# {s}\n\nStub generated module.\n", .{opts.module_name});
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.generated.md", .{opts.module_name});
    try files.append(alloc, .{ .path = readme_path, .contents = gen_readme });
    return Generated{ .files = try files.toOwnedSlice(alloc) };
}
