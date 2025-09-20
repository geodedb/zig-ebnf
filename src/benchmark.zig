const std = @import("std");
const lib = @import("lib.zig");

/// Simple benchmark program for parsing, generating, and recognizing grammars.
pub fn main() !void {
    var gpa = std.heap.page_allocator;

    // Benchmark integer grammar parse and codegen
    const int_code = @embedFile("examples/integer.ebnf");
    var start_ns = std.time.nanoTimestamp();
    var ast_int = try lib.parseEbnf(gpa, int_code);
    var parse_end_ns = std.time.nanoTimestamp();
    defer ast_int.deinit();

    const int_opts = lib.GenOptions{
        .backend = .RecursiveDescent,
        .module_name = "bench_integer",
        .start_rule = "integer",
    };
    var gen_int = try lib.generateZig(gpa, &ast_int, int_opts);
    var gen_end_ns = std.time.nanoTimestamp();
    defer gpa.free(gen_int.files);

    // Benchmark recognition for integer grammar
    var rec_start_ns = std.time.nanoTimestamp();
    var result = try lib.recognize(gpa, &ast_int, "integer", "+142");
    var rec_end_ns = std.time.nanoTimestamp();
    _ = result;

    const parse_us = (parse_end_ns - start_ns) / 1000;
    const gen_us = (gen_end_ns - parse_end_ns) / 1000;
    const rec_us = (rec_end_ns - rec_start_ns) / 1000;
    std.debug.print("integer parse: {d} us\n", .{parse_us});
    std.debug.print("integer generate: {d} us\n", .{gen_us});
    std.debug.print("integer recognize: {d} us\n", .{rec_us});

    // Benchmark integer_set grammar parse and generate
    const intset_code = @embedFile("examples/integer_set.ebnf");
    start_ns = std.time.nanoTimestamp();
    var ast_set = try lib.parseEbnf(gpa, intset_code);
    parse_end_ns = std.time.nanoTimestamp();
    defer ast_set.deinit();
    const set_opts = lib.GenOptions{
        .backend = .RecursiveDescent,
        .module_name = "bench_intset",
        .start_rule = "integer_set",
    };
    var gen_set = try lib.generateZig(gpa, &ast_set, set_opts);
    gen_end_ns = std.time.nanoTimestamp();
    defer gpa.free(gen_set.files);
    rec_start_ns = std.time.nanoTimestamp();
    var set_result = try lib.recognize(gpa, &ast_set, "integer_set", "{5,-2,11}");
    rec_end_ns = std.time.nanoTimestamp();
    _ = set_result;

    const parse_set_us = (parse_end_ns - start_ns) / 1000;
    const gen_set_us = (gen_end_ns - parse_end_ns) / 1000;
    const rec_set_us = (rec_end_ns - rec_start_ns) / 1000;
    std.debug.print("integer_set parse: {d} us\n", .{parse_set_us});
    std.debug.print("integer_set generate: {d} us\n", .{gen_set_us});
    std.debug.print("integer_set recognize: {d} us\n", .{rec_set_us});
}
