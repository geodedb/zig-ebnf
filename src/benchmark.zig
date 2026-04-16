const std = @import("std");
const lib = @import("lib.zig");

inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Zig 0.16.0 replacement for std.time.nanoTimestamp.
fn nanoTimestamp() i96 {
    return std.Io.Clock.Timestamp.now(io(), .real).raw.nanoseconds;
}

/// Simple benchmark program for parsing, generating, and recognizing grammars.
pub fn main() !void {
    const gpa = std.heap.page_allocator;

    // Benchmark integer grammar parse and codegen
    const int_code = @embedFile("../examples/integer.ebnf");
    var start_ns = nanoTimestamp();
    var ast_int = try lib.parseEbnf(gpa, int_code);
    var parse_end_ns = nanoTimestamp();
    defer ast_int.deinit();

    const int_opts = lib.GenOptions{
        .backend = .RecursiveDescent,
        .module_name = "bench_integer",
        .start_rule = "integer",
    };
    var gen_int = try lib.generateZig(gpa, &ast_int, int_opts);
    var gen_end_ns = nanoTimestamp();
    defer gen_int.deinit(gpa);

    // Benchmark recognition for integer grammar
    var rec_start_ns = nanoTimestamp();
    const result = try lib.recognize(gpa, &ast_int, "integer", "+142");
    var rec_end_ns = nanoTimestamp();
    _ = result;

    const parse_us = @divTrunc(parse_end_ns - start_ns, 1000);
    const gen_us = @divTrunc(gen_end_ns - parse_end_ns, 1000);
    const rec_us = @divTrunc(rec_end_ns - rec_start_ns, 1000);
    std.debug.print("integer parse: {d} us\n", .{parse_us});
    std.debug.print("integer generate: {d} us\n", .{gen_us});
    std.debug.print("integer recognize: {d} us\n", .{rec_us});

    // Benchmark integer_set grammar parse and generate
    const intset_code = @embedFile("../examples/integer_set.ebnf");
    start_ns = nanoTimestamp();
    var ast_set = try lib.parseEbnf(gpa, intset_code);
    parse_end_ns = nanoTimestamp();
    defer ast_set.deinit();
    const set_opts = lib.GenOptions{
        .backend = .RecursiveDescent,
        .module_name = "bench_intset",
        .start_rule = "integer_set",
    };
    var gen_set = try lib.generateZig(gpa, &ast_set, set_opts);
    gen_end_ns = nanoTimestamp();
    defer gen_set.deinit(gpa);
    rec_start_ns = nanoTimestamp();
    const set_result = try lib.recognize(gpa, &ast_set, "integer_set", "{5,-2,11}");
    rec_end_ns = nanoTimestamp();
    _ = set_result;

    const parse_set_us = @divTrunc(parse_end_ns - start_ns, 1000);
    const gen_set_us = @divTrunc(gen_end_ns - parse_end_ns, 1000);
    const rec_set_us = @divTrunc(rec_end_ns - rec_start_ns, 1000);
    std.debug.print("integer_set parse: {d} us\n", .{parse_set_us});
    std.debug.print("integer_set generate: {d} us\n", .{gen_set_us});
    std.debug.print("integer_set recognize: {d} us\n", .{rec_set_us});
}
