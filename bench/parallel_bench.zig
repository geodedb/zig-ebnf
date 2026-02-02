//! EBNF Parallel Operations Benchmark

const std = @import("std");
const parallel = @import("parallel");

const WARMUP_RUNS = 3;
const BENCH_RUNS = 5;

const BenchResult = struct {
    seq_ns: u64,
    par_ns: u64,

    fn speedup(self: BenchResult) f64 {
        if (self.par_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.seq_ns)) / @as(f64, @floatFromInt(self.par_ns));
    }

    fn seqMs(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.seq_ns)) / 1_000_000.0;
    }

    fn parMs(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.par_ns)) / 1_000_000.0;
    }
};

// Simulated rule type for testing
const Rule = struct {
    name: []const u8,
    valid: bool,
};

fn isValidRule(rule: Rule) bool {
    // Simulate some validation work
    return rule.valid and rule.name.len > 0;
}

fn isEven(x: i32) bool {
    return @mod(x, 2) == 0;
}

fn benchParallelRuleProcessing(allocator: std.mem.Allocator, num_rules: usize) !BenchResult {
    const rules = try allocator.alloc(Rule, num_rules);
    defer allocator.free(rules);

    for (rules, 0..) |*rule, i| {
        rule.* = .{
            .name = "test_rule",
            .valid = @mod(i, 3) != 0, // 2/3 are valid
        };
    }

    var results = try allocator.alloc(bool, num_rules);
    defer allocator.free(results);

    // Sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        var valid_count: usize = 0;
        for (rules, 0..) |rule, i| {
            results[i] = isValidRule(rule);
            if (results[i]) valid_count += 1;
        }
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&valid_count);
    }

    // Parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const count = parallel.parallelProcessRules(Rule, rules, results, isValidRule);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&count);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn benchParallelCount(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const items = try allocator.alloc(i32, size);
    defer allocator.free(items);

    for (items, 0..) |*item, i| item.* = @intCast(i);

    // Sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        var count: usize = 0;
        for (items) |item| {
            if (isEven(item)) count += 1;
        }
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&count);
    }

    // Parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const count = parallel.parallelCount(i32, items, isEven);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&count);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn printBenchResult(name: []const u8, size: usize, result: BenchResult) void {
    const speedup = result.speedup();
    const indicator: []const u8 = if (speedup >= 1.5) " [FAST]" else if (speedup >= 1.0) " [OK]" else " [SLOW]";
    std.debug.print("{s:<18} {d:>10} {d:>10.3} ms {d:>10.3} ms {d:>8.2}x{s}\n", .{
        name,
        size,
        result.seqMs(),
        result.parMs(),
        speedup,
        indicator,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("========================================================================\n", .{});
    std.debug.print("          EBNF Library - Spice Parallel Operations Benchmark           \n", .{});
    std.debug.print("========================================================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Warmup: {d} runs, Benchmark: {d} runs (averaged)\n", .{ WARMUP_RUNS, BENCH_RUNS });
    std.debug.print("Legend: [FAST] = >1.5x speedup, [OK] = faster, [SLOW] = slower\n\n", .{});

    std.debug.print("{s:<18} {s:>10} {s:>12} {s:>12} {s:>10}\n", .{ "Operation", "Size", "Sequential", "Parallel", "Speedup" });
    std.debug.print("{s:->18} {s:->10} {s:->12} {s:->12} {s:->10}\n", .{ "", "", "", "", "" });

    // Rule processing benchmark
    const rule_sizes = [_]usize{ 100, 1_000, 10_000, 50_000 };
    for (rule_sizes) |size| {
        const result = try benchParallelRuleProcessing(allocator, size);
        printBenchResult("Rule Validation", size, result);
    }
    std.debug.print("\n", .{});

    // Count benchmark
    const count_sizes = [_]usize{ 1_000, 10_000, 100_000, 1_000_000 };
    for (count_sizes) |size| {
        const result = try benchParallelCount(allocator, size);
        printBenchResult("Count (isEven)", size, result);
    }

    std.debug.print("\n", .{});
}
