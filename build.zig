const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protocol = b.addModule("bedrock_protocol", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mock_profile = b.createModule(.{
        .root_source_file = b.path("tests/support/mock_profile.zig"),
        .imports = &.{.{ .name = "bedrock_protocol", .module = protocol }},
    });

    const test_step = b.step("test", "Run unit, corpus and generated-codec tests");
    const options = b.addOptions();
    const corpus_file = b.option([]const u8, "corpus", "Packet corpus to replay (default: tests/corpus.txt)") orelse b.pathFromRoot("tests/corpus.txt");
    options.addOption([]const u8, "corpus_file", corpus_file);

    const suite = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bedrock_protocol", .module = protocol },
            .{ .name = "mock_profile", .module = mock_profile },
            .{ .name = "build_options", .module = options.createModule() },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(suite).step);
    const inline_tests = b.addTest(.{ .root_module = protocol });
    test_step.dependOn(&b.addRunArtifact(inline_tests).step);

    // Profiles with the wrong function signatures must not compile.
    const invalid_profile = b.addObject(.{ .name = "invalid-profile", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/integration/invalid_profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "bedrock_protocol", .module = protocol }},
    }) });
    invalid_profile.expect_errors = .{ .contains = "incompatible profile function parameter" };
    test_step.dependOn(&invalid_profile.step);

    const fuzz_options = b.addOptions();
    fuzz_options.addOption(usize, "iterations", b.option(usize, "fuzz-iterations", "Deterministic fuzz cases (default: 100000)") orelse 100_000);
    fuzz_options.addOption([]const u8, "corpus_file", corpus_file);
    const fuzz = b.addExecutable(.{ .name = "protocol-fuzz", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bedrock_protocol", .module = protocol },
            .{ .name = "mock_profile", .module = mock_profile },
            .{ .name = "fuzz_options", .module = fuzz_options.createModule() },
        },
    }) });
    b.step("fuzz", "Run a bounded deterministic hostile-input campaign").dependOn(&b.addRunArtifact(fuzz).step);

    const bench_optimize = b.option(std.builtin.OptimizeMode, "bench-optimize", "Benchmark optimization mode (default: ReleaseFast)") orelse .ReleaseFast;
    const bench_protocol = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = bench_optimize });
    const bench_options = b.addOptions();
    bench_options.addOption([]const u8, "corpus_file", corpus_file);
    const bench = b.addExecutable(.{ .name = "protocol-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/bench/main.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "bedrock_protocol", .module = bench_protocol },
            .{ .name = "mock_profile", .module = b.createModule(.{
                .root_source_file = b.path("tests/support/mock_profile.zig"),
                .imports = &.{.{ .name = "bedrock_protocol", .module = bench_protocol }},
            }) },
            .{ .name = "bench_options", .module = bench_options.createModule() },
        },
    }) });
    b.step("bench", "Run microbenchmarks").dependOn(&b.addRunArtifact(bench).step);

    const check = b.step("check", "Compile the tests, fuzzer and benchmarks without running them");
    for ([_]*std.Build.Step{ &suite.step, &inline_tests.step, &fuzz.step, &bench.step, &invalid_profile.step }) |step| check.dependOn(step);

    if (b.option([]const u8, "bedwire-path", "Path to a Bedwire checkout")) |path| {
        const bedwire = b.createModule(.{
            .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ path, "src/root.zig" }) },
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bedrock_protocol", .module = protocol }},
        });
        const integration = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/bedwire.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bedrock_protocol", .module = protocol },
                .{ .name = "bedwire", .module = bedwire },
                .{ .name = "mock_profile", .module = mock_profile },
            },
        }) });
        b.step("test-bedwire", "Run Bedwire sessions over this library").dependOn(&b.addRunArtifact(integration).step);
    }
}
