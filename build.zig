const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Benchmark optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    const module = b.addModule("bedrock_protocol", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mock_module = b.createModule(.{ .root_source_file = b.path("src/tests/fixtures/mock_profile.zig"), .target = target, .optimize = optimize });
    module.addImport("mock_profile", mock_module);
    const bench_dep = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{.{
            .name = "bedrock_protocol",
            .module = bench_dep,
        }},
    });

    bench_mod.addImport("mock_profile", mock_module);
    bench_dep.addImport("mock_profile", mock_module);
    const tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run protocol tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const bad_profile = b.addObject(.{ .name = "invalid-profile", .root_module = b.createModule(.{
        .root_source_file = b.path("integration/invalid_profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "bedrock_protocol", .module = module }},
    }) });
    bad_profile.expect_errors = .{ .contains = "incompatible profile function parameter" };
    test_step.dependOn(&bad_profile.step);
    const bench = b.addExecutable(.{
        .name = "protocol-bench",
        .root_module = bench_mod,
    });
    const bench_step = b.step("bench", "Run microbenchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench).step);

    const fuzz_options = b.addOptions();
    fuzz_options.addOption(usize, "iterations", b.option(usize, "fuzz-iterations", "Deterministic fuzz cases") orelse 100_000);
    const fuzz_module = b.createModule(.{ .root_source_file = b.path("src/fuzz_main.zig"), .target = target, .optimize = optimize });
    fuzz_module.addImport("mock_profile", mock_module);
    fuzz_module.addOptions("fuzz_options", fuzz_options);
    const fuzz = b.addExecutable(.{ .name = "protocol-fuzz", .root_module = fuzz_module });
    b.step("fuzz", "Run bounded deterministic hostile-input campaigns").dependOn(&b.addRunArtifact(fuzz).step);
    if (b.option([]const u8, "bedwire-path", "Path to pinned Bedwire checkout")) |path| {
        const bedwire = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ path, "src/root.zig" }) }, .target = target, .optimize = optimize });
        bedwire.addImport("bedrock_protocol", module);
        const integration = b.createModule(.{ .root_source_file = b.path("integration/bedwire.zig"), .target = target, .optimize = optimize });
        integration.addImport("bedwire", bedwire);
        integration.addImport("bedrock_protocol", module);
        integration.addImport("mock_profile", mock_module);
        const consumer = b.addTest(.{ .root_module = integration });
        b.step("test-bedwire", "Run real Bedwire profile consumer tests").dependOn(&b.addRunArtifact(consumer).step);
    }
}
