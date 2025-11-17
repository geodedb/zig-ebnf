const std = @import("std");
const lib = @import("ebnfgen");

const Version = "0.1.0";

fn printUsage() void {
    std.debug.print(
        \\
        \\zig-ebnf generate  (--in|--grammar) <grammar.ebnf> [--out <dir>] [--start <rule>] [--module-name <name>] [--backend rd|stub] [--permissive] [--emit-cli-demo]
        \\  (Positional form also accepted: zig-ebnf generate <grammar.ebnf>)
        \\  Defaults: --out ./zig-ebnf-out, --start first-rule, --module-name generated
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
    var out_dir: []const u8 = "zig-ebnf-out";
    var start_rule: ?[]const u8 = null;
    var module_name: []const u8 = "generated";
    var permissive = false;
    var backend: lib.GenBackend = .RecursiveDescent;
    var emit_cli_demo = false;

    // Collect positional (first non-flag) as grammar if --in/--grammar absent.
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--in") or std.mem.eql(u8, a, "--grammar")) {
            if (i + 1 >= argv.len) return error.InvalidArgument;
            in_path = argv[i + 1];
            i += 1;
            continue;
        } else if (std.mem.eql(u8, a, "--out")) {
            if (i + 1 >= argv.len) return error.InvalidArgument;
            out_dir = argv[i + 1];
            i += 1;
            continue;
        } else if (std.mem.eql(u8, a, "--start")) {
            if (i + 1 >= argv.len) return error.InvalidArgument;
            start_rule = argv[i + 1];
            i += 1;
            continue;
        } else if (std.mem.eql(u8, a, "--module-name")) {
            if (i + 1 >= argv.len) return error.InvalidArgument;
            module_name = argv[i + 1];
            i += 1;
            continue;
        } else if (std.mem.eql(u8, a, "--permissive")) {
            permissive = true;
            continue;
        } else if (std.mem.eql(u8, a, "--backend")) {
            if (i + 1 >= argv.len) return error.InvalidArgument;
            const bname = argv[i + 1];
            if (std.mem.eql(u8, bname, "rd")) backend = .RecursiveDescent else if (std.mem.eql(u8, bname, "stub")) backend = .Stub else return error.InvalidArgument;
            i += 1;
            continue;
        } else if (std.mem.eql(u8, a, "--emit-cli-demo")) {
            emit_cli_demo = true;
            continue;
        } else if (a.len > 0 and a[0] != '-') {
            // positional grammar if not set yet
            if (in_path == null) in_path = a; // ignore extras
        }
    }
    if (in_path == null) {
        printUsage();
        return error.InvalidArgument;
    }

    // Read grammar
    var file = try std.fs.cwd().openFile(in_path.?, .{});
    defer file.close();
    const code = try file.readToEndAlloc(alloc, 64 * 1024 * 1024);
    defer alloc.free(code);

    var astv = lib.parseEbnfOpts(alloc, code, .{ .permissive = permissive }) catch |e| switch (e) {
        lib.Error.UndefinedSymbol => {
            // Attempt to parse again to capture diagnostics if not already populated (parser populates during initial pass).
            // astv not constructed on failure; reparse permissive same mode just to gather (would fail again fast).
            var tmp = lib.parseEbnfOpts(alloc, code, .{ .permissive = permissive }) catch return e;
            defer tmp.deinit();
            if (tmp.last_undef_names.len > 0) {
                std.debug.print("Undefined symbols (first {d}):\n", .{tmp.last_undef_names.len});
                var j: usize = 0;
                while (j < tmp.last_undef_names.len) : (j += 1) {
                    const sp = tmp.last_undef_spans[j];
                    std.debug.print("  {s} at line {d} col {d}\n", .{ tmp.last_undef_names[j], sp.line, sp.col });
                }
            } else {
                std.debug.print("Undefined symbols encountered.\n", .{});
            }
            return e;
        },
        else => return e,
    };
    defer astv.deinit();

    const gen = lib.GenOptions{
        .backend = backend,
        .module_name = module_name,
        .start_rule = start_rule orelse blk: {
            if (astv.rules.len == 0) return error.InvalidArgument;
            break :blk astv.rules[0].name;
        },
        .emit_cli_demo = emit_cli_demo,
    };
    var out = try lib.generateZig(alloc, &astv, gen);
    defer out.deinit(alloc);

    // Write files under out_dir/module_name/...
    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);

    const base = try lib.runtime.sanitizeJoin(alloc, out_dir, module_name, &buf);
    try std.fs.cwd().makePath(base);
    for (out.files) |gf| {
        // gf.path is "<module>/mod.zig" etc: join base + tail after module name
        var rel = gf.path[module_name.len..]; // starts with '/...'
        if (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];

        var full = std.ArrayList(u8).init(alloc);
        defer full.deinit();
        try full.appendSlice(base);
        try full.append(std.fs.path.sep);
        try full.appendSlice(rel);

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
