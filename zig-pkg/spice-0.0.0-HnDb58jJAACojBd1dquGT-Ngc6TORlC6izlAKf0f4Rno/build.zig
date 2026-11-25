const std = @import("std");

// Spice library build configuration
//
// Supports both OS-backed threading and freestanding (kernel/bare-metal)
// cooperative mode. On freestanding targets, fork/join degrades gracefully
// to sequential execution while preserving the identical public API.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Export the spice module
    _ = b.addModule("spice", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Native tests (run on host with OS threads)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Freestanding compilation checks (verify it compiles, cannot run)
    const freestanding_targets = [_]std.Target.Cpu.Arch{
        .riscv64,
        .riscv32,
        .aarch64,
        .arm,
        .x86_64,
        .x86,
    };

    const freestanding_step = b.step("check-freestanding", "Verify freestanding compilation for all architectures");

    for (freestanding_targets) |arch| {
        const freestanding_lib = b.addLibrary(.{
            .name = b.fmt("spice-{s}-freestanding", .{@tagName(arch)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = arch,
                    .os_tag = .freestanding,
                    .abi = .none,
                }),
                .optimize = optimize,
            }),
        });
        freestanding_step.dependOn(&freestanding_lib.step);
    }
}
