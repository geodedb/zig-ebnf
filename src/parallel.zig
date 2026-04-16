// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel EBNF operations using thread-pool batch submission.
//!
//! Provides parallel processing for grammar validation and code generation.

const std = @import("std");
const build_options = @import("build_options");
const tp = if (build_options.enable_tp) @import("thread_pool") else struct {
    pub const ThreadPool = void;
    pub const TaskContext = void;
    pub const BatchTask = void;
    pub const WaitGroup = void;
};

var global_pool: if (build_options.enable_tp) ?tp.ThreadPool else void = if (build_options.enable_tp) null else {};
var pool_mutex: if (build_options.enable_tp) tp.sync.Mutex else void = if (build_options.enable_tp) .{} else {};

pub fn getPool() if (build_options.enable_tp) *tp.ThreadPool else void {
    if (!build_options.enable_tp) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = tp.ThreadPool.init(std.heap.page_allocator, .{}) catch @panic("thread-pool: init failed");
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    if (!build_options.enable_tp) return;

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

fn RuleChunk(comptime T: type) type {
    return struct {
        rules: []const T,
        results: []bool,
        valid_count: usize,
        validate_fn: *const fn (T) bool,
    };
}

fn ruleChunkTask(comptime T: type) *const fn (*anyopaque, *tp.TaskContext) void {
    return struct {
        fn run(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
            const chunk: *RuleChunk(T) = @ptrCast(@alignCast(ctx_ptr));
            var count: usize = 0;
            for (chunk.rules, 0..) |rule, i| {
                chunk.results[i] = chunk.validate_fn(rule);
                if (chunk.results[i]) count += 1;
            }
            chunk.valid_count = count;
        }
    }.run;
}

const MAX_CHUNKS = 64;

/// Process grammar rules in parallel (e.g., for validation)
pub fn parallelProcessRules(
    comptime T: type,
    rules: []const T,
    results: []bool,
    comptime validateFn: fn (T) bool,
) usize {
    std.debug.assert(rules.len == results.len);

    const THRESHOLD = 8;

    if (!build_options.enable_tp or rules.len < THRESHOLD) {
        var valid_count: usize = 0;
        for (rules, 0..) |rule, i| {
            results[i] = validateFn(rule);
            if (results[i]) valid_count += 1;
        }
        return valid_count;
    }

    const pool = getPool();
    const chunk_size = @max(THRESHOLD, rules.len / MAX_CHUNKS);

    var chunks: [MAX_CHUNKS]RuleChunk(T) = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;

    while (i < rules.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, rules.len);
        chunks[n] = .{
            .rules = rules[i..end],
            .results = results[i..end],
            .valid_count = 0,
            .validate_fn = &validateFn,
        };
        batch[n] = .{ .task_fn = ruleChunkTask(T), .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        var valid_count: usize = 0;
        for (rules, 0..) |rule, j| {
            results[j] = validateFn(rule);
            if (results[j]) valid_count += 1;
        }
        return valid_count;
    };
    wg.wait();

    var total: usize = 0;
    for (chunks[0..n]) |chunk| total += chunk.valid_count;
    return total;
}

// ============================================================================
// Parallel Count
// ============================================================================

fn CountChunk(comptime T: type) type {
    return struct {
        items: []const T,
        count: usize,
        predicate_fn: *const fn (T) bool,
    };
}

fn countChunkTask(comptime T: type) *const fn (*anyopaque, *tp.TaskContext) void {
    return struct {
        fn run(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
            const chunk: *CountChunk(T) = @ptrCast(@alignCast(ctx_ptr));
            var c: usize = 0;
            for (chunk.items) |item| {
                if (chunk.predicate_fn(item)) c += 1;
            }
            chunk.count = c;
        }
    }.run;
}

/// Parallel count of unique items
pub fn parallelCount(
    comptime T: type,
    items: []const T,
    comptime predicate: fn (T) bool,
) usize {
    const THRESHOLD = 64;

    if (!build_options.enable_tp or items.len < THRESHOLD) {
        var count: usize = 0;
        for (items) |item| {
            if (predicate(item)) count += 1;
        }
        return count;
    }

    const pool = getPool();
    const chunk_size = @max(THRESHOLD, items.len / MAX_CHUNKS);

    var chunks: [MAX_CHUNKS]CountChunk(T) = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;

    while (i < items.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, items.len);
        chunks[n] = .{
            .items = items[i..end],
            .count = 0,
            .predicate_fn = &predicate,
        };
        batch[n] = .{ .task_fn = countChunkTask(T), .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        var count: usize = 0;
        for (items) |item| {
            if (predicate(item)) count += 1;
        }
        return count;
    };
    wg.wait();

    var total: usize = 0;
    for (chunks[0..n]) |chunk| total += chunk.count;
    return total;
}

test "parallel count" {
    if (!build_options.enable_tp) return error.SkipZigTest;

    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const count = parallelCount(i32, &items, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try std.testing.expectEqual(@as(usize, 5), count);
}
