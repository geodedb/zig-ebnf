const std = @import("std");
const lib = @import("ebnfgen");

const Version = "0.1.0";

fn printUsage() void {
    std.debug.print(
        \\
        \\zig-ebnf generate  --in <grammar.ebnf> --out <dir> --start <rule> [--module-name <name>]
        \\zig-ebnf recognize --grammar <grammar.ebnf> --start <rule> --input <str>
        \\zig-ebnf version
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.page_allocator;

    var args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version")) {
        std.debug.print("zig-ebnfgen {s}\n", .{Version});
        const zigv = try std.process.getEnvVarOwned(gpa, "ZIG_VERSION");
        defer gpa.free(zigv);
        // If env not set, we still print compile-time version using builtin
        std.debug.print("zig {s}\n", .{@import("builtin").zig_version_string});
        return;
    } else if (std.mem.eql(u8, cmd, "generate")) {
        try cmdGenerate(gpa, args[2..]);
    } else if (std.mem.eql(u8, cmd, "recognize")) {
        try cmdRecognize(gpa, args[2..]);
    } else {
        printUsage();
    }
}

fn cmdGenerate(alloc: std.mem.Allocator, argv: [][:0]u8) !void {
    var in_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var start_rule: ?[]const u8 = null;
    var module_name: []const u8 = "generated";

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--in") and i + 1 < argv.len) {
            in_path = argv[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--out") and i + 1 < argv.len) {
            out_dir = argv[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--start") and i + 1 < argv.len) {
            start_rule = argv[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--module-name") and i + 1 < argv.len) {
            module_name = argv[i + 1];
            i += 1;
            continue;
        }
    }
    if (in_path == null or out_dir == null or start_rule == null) {
        printUsage();
        return error.InvalidArgument;
    }

    // Read grammar
    var file = try std.fs.cwd().openFile(in_path.?, .{ .mode = .read_only });
    defer file.close();
    const code = try file.readToEndAlloc(alloc, 64 * 1024 * 1024);
    defer alloc.free(code);

    var astv = try lib.parseEbnf(alloc, code);
    defer astv.deinit();

    const gen = lib.GenOptions{
        .backend = .RecursiveDescent,
        .module_name = module_name,
        .start_rule = start_rule.?,
    };
    const out = try lib.generateZig(alloc, &astv, gen);
    defer alloc.free(out.files);

    // Write files under out_dir/module_name/...
    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);

    const base = try lib.runtime.sanitizeJoin(alloc, out_dir.?, module_name, &buf);
    try std.fs.cwd().makePath(base);
    for (out.files) |gf| {
        // gf.path is "<module>/mod.zig" etc: join base + tail after module name
        var rel = gf.path[module_name.len..]; // starts with '/...'
        if (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];

        var full = std.ArrayList(u8){};
        defer full.deinit(alloc);
        try full.appendSlice(alloc, base);
        try full.append(alloc, std.fs.path.sep);
        try full.appendSlice(alloc, rel);

        // ensure directory exists
        const dir = std.fs.path.dirname(full.items) orelse base;
        try std.fs.cwd().makePath(dir);

        var f = try std.fs.cwd().createFile(full.items, .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll(gf.contents);
    }
}

fn cmdRecognize(alloc: std.mem.Allocator, argv: [][:0]u8) !void {
    var grammar_path: ?[]const u8 = null;
    var start_rule: ?[]const u8 = null;
    var input: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--grammar") and i + 1 < argv.len) {
            grammar_path = argv[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--start") and i + 1 < argv.len) {
            start_rule = argv[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--input") and i + 1 < argv.len) {
            input = argv[i + 1];
            i += 1;
            continue;
        }
    }
    if (grammar_path == null or start_rule == null or input == null) {
        printUsage();
        return error.InvalidArgument;
    }

    var f = try std.fs.cwd().openFile(grammar_path.?, .{});
    defer f.close();
    const src = try f.readToEndAlloc(alloc, 64 * 1024 * 1024);
    defer alloc.free(src);

    var astv = try lib.parseEbnf(alloc, src);
    defer astv.deinit();

    // Additional validations for CLI
    try astv.checkReachability(start_rule.?);
    try astv.checkEmptyRepetition();
    try astv.checkLeftRecursion();

    const res = try lib.recognize(alloc, &astv, start_rule.?, input.?);
    if (res.ok) {
        std.debug.print("ACCEPT {s} \"{s}\"\n", .{ start_rule.?, input.? });
        return;
    }
    // For "Unexpected" errors, try to print the char at index if exists.
    if (std.mem.eql(u8, res.reason, "Trailing input")) {
        std.debug.print("REJECT {s} \"{s}\": Trailing input @{d}\n", .{ start_rule.?, input.?, res.index });
    } else {
        const idx = if (res.index < input.?.len) res.index else input.?.len;
        const ch: u8 = if (idx < input.?.len) input.?[idx] else 0;
        if (idx < input.?.len) {
            std.debug.print("REJECT {s} \"{s}\": Unexpected \"{c}\" @{d}\n", .{ start_rule.?, input.?, ch, idx });
        } else {
            std.debug.print("REJECT {s} \"{s}\": Unexpected @{d}\n", .{ start_rule.?, input.?, idx });
        }
        std.process.exit(1);
    }
}
