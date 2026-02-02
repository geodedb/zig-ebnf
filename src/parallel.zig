// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel EBNF operations using spice heartbeat scheduling.
//!
//! Provides parallel processing for grammar validation and code generation.

const std = @import("std");
const build_options = @import("build_options");
const spice = if (build_options.enable_spice) @import("spice") else struct {
    pub const ThreadPool = void;
    pub const Task = void;
    pub fn Future(comptime I: type, comptime O: type) type {
        _ = I;
        _ = O;
        return void;
    }
};

var global_pool: if (build_options.enable_spice) ?spice.ThreadPool else void = if (build_options.enable_spice) null else {};
var pool_mutex: std.Thread.Mutex = .{};

pub fn getPool() if (build_options.enable_spice) *spice.ThreadPool else void {
    if (!build_options.enable_spice) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = spice.ThreadPool.init(std.heap.page_allocator);
        global_pool.?.start(.{});
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    if (!build_options.enable_spice) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |*pool| {
        pool.deinit();
        global_pool = null;
    }
}

// ============================================================================
// Parallel Rule Processing
// ============================================================================

pub fn RuleContext(comptime T: type) type {
    return struct {
        rules: []const T,
        results: []bool,
    };
}

/// Process grammar rules in parallel (e.g., for validation)
pub fn parallelProcessRules(
    comptime T: type,
    rules: []const T,
    results: []bool,
    comptime validateFn: fn (T) bool,
) usize {
    std.debug.assert(rules.len == results.len);

    if (!build_options.enable_spice or rules.len < 8) {
        var valid_count: usize = 0;
        for (rules, 0..) |rule, i| {
            results[i] = validateFn(rule);
            if (results[i]) valid_count += 1;
        }
        return valid_count;
    }

    const pool = getPool();
    const Ctx = RuleContext(T);
    return pool.call(usize, ParallelRuleTask(T, validateFn).task, Ctx{ .rules = rules, .results = results });
}

fn ParallelRuleTask(comptime T: type, comptime validateFn: fn (T) bool) type {
    const Ctx = RuleContext(T);
    return struct {
        pub fn task(t: *spice.Task, ctx: Ctx) usize {
            const rules = ctx.rules;
            const results = ctx.results;

            if (rules.len < 4) {
                var valid_count: usize = 0;
                for (rules, 0..) |rule, i| {
                    results[i] = validateFn(rule);
                    if (results[i]) valid_count += 1;
                }
                return valid_count;
            }

            const mid = rules.len / 2;
            const left_ctx = Ctx{ .rules = rules[0..mid], .results = results[0..mid] };
            const right_ctx = Ctx{ .rules = rules[mid..], .results = results[mid..] };

            var fut = spice.Future(Ctx, usize).init();
            fut.fork(t, task, right_ctx);

            const left_count = t.call(usize, task, left_ctx);
            const right_count = if (fut.join(t)) |val| val else t.call(usize, task, right_ctx);

            return left_count + right_count;
        }
    };
}

// ============================================================================
// Parallel Terminal Collection
// ============================================================================

/// Parallel count of unique items
pub fn parallelCount(
    comptime T: type,
    items: []const T,
    comptime predicate: fn (T) bool,
) usize {
    if (!build_options.enable_spice or items.len < 64) {
        var count: usize = 0;
        for (items) |item| {
            if (predicate(item)) count += 1;
        }
        return count;
    }

    const pool = getPool();
    return pool.call(usize, ParallelCountTask(T, predicate).task, items);
}

fn ParallelCountTask(comptime T: type, comptime predicate: fn (T) bool) type {
    return struct {
        pub fn task(t: *spice.Task, items: []const T) usize {
            if (items.len < 32) {
                var count: usize = 0;
                for (items) |item| {
                    if (predicate(item)) count += 1;
                }
                return count;
            }

            const mid = items.len / 2;
            const left = items[0..mid];
            const right = items[mid..];

            var fut = spice.Future([]const T, usize).init();
            fut.fork(t, task, right);

            const left_count = t.call(usize, task, left);
            const right_count = if (fut.join(t)) |val| val else t.call(usize, task, right);

            return left_count + right_count;
        }
    };
}

test "parallel count" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const count = parallelCount(i32, &items, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try std.testing.expectEqual(@as(usize, 5), count);
}
