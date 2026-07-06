const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_spice = b.option(bool, "spice", "Enable spice-based parallelism") orelse true;

    // Build options module
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_spice", enable_spice);

    // Get spice dependency if enabled
    const spice_mod: ?*std.Build.Module = if (enable_spice) blk: {
        const spice_dep = b.dependency("spice", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk spice_dep.module("spice");
    } else null;

    // Parallel module
    const parallel_mod = b.addModule("parallel", .{
        .root_source_file = b.path("src/parallel.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });
    if (spice_mod) |sm| {
        parallel_mod.addImport("spice", sm);
    }

    // Library module exposed to dependents
    _ = b.addModule("ebnf", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "zig-ebnf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addAnonymousImport("ebnfgen", .{
        .root_source_file = b.path("src/lib.zig"),
    });
    b.installArtifact(exe);

    // `zig build run -- ...`
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zig-ebnf").dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addAnonymousImport("iso_gql_bnf", .{
        .root_source_file = b.path("testdata/ISO_IEC_39075.bnf.txt"),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Benchmark executable
    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark.root_module.addAnonymousImport("ebnfgen", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    const bench_install = b.addInstallArtifact(benchmark, .{});
    b.step("bench", "Build benchmark executable").dependOn(&bench_install.step);

    const bench_run = b.addRunArtifact(benchmark);
    b.step("run-bench", "Run benchmark").dependOn(&bench_run.step);

    // Parallel benchmark
    const parallel_bench_step = b.step("bench-parallel", "Run parallel operations benchmark");
    const parallel_bench_exe = b.addExecutable(.{
        .name = "parallel_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/parallel_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "parallel", .module = parallel_mod },
            },
        }),
    });
    const run_parallel_bench = b.addRunArtifact(parallel_bench_exe);
    parallel_bench_step.dependOn(&run_parallel_bench.step);
}
