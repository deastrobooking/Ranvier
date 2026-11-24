const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("ranvier", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Ranvier Core unit tests");
    test_step.dependOn(&run_tests.step);

    // Compile-fail fixtures: the build succeeds only if each one is rejected
    // with a diagnostic line ending in the expected text.
    inline for (.{
        .{ "undeclared_read", "component not declared by query" },
        .{ "write_readonly", "component not declared writable" },
        .{ "overlapping_access", "read/write query sets must be disjoint" },
        .{ "unregistered_component", "component is not registered: unregistered_component.Unregistered" },
    }) |case| {
        const obj = b.addObject(.{
            .name = "compile-fail-" ++ case[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/compile_fail/" ++ case[0] ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "ranvier", .module = mod }},
            }),
        });
        obj.expect_errors = .{ .contains = case[1] };
        test_step.dependOn(&obj.step);
    }

    const example = b.addExecutable(.{
        .name = "ranvier-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ranvier", .module = mod }},
        }),
    });
    const run_example = b.addRunArtifact(example);
    b.step("demo", "Run the memory, layout and binary demo").dependOn(&run_example.step);
    b.installArtifact(example);
    const ecs_example = b.addExecutable(.{
        .name = "ranvier-ecs-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/ecs_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ranvier", .module = mod }},
        }),
    });
    const run_ecs = b.addRunArtifact(ecs_example);
    b.step("ecs-demo", "Run the archetype ECS and task graph demo").dependOn(&run_ecs.step);

    const bench_step = b.step("bench", "Build the three layout benchmark executables");
    inline for (.{ "aos", "soa", "aosoa" }) |layout| {
        const exe = b.addExecutable(.{
            .name = "ranvier-bench-" ++ layout,
            .root_module = b.createModule(.{
                .root_source_file = b.path("benchmarks/" ++ layout ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "ranvier", .module = mod }},
            }),
        });
        const install = b.addInstallArtifact(exe, .{});
        bench_step.dependOn(&install.step);
    }
    const ecs_bench = b.step("bench-ecs", "Build ECS and flat AoS benchmark executables");
    inline for (.{ .{ "ecs", "ecs" }, .{ "aos", "ecs_aos" } }) |entry| {
        const exe = b.addExecutable(.{
            .name = "ranvier-ecs-bench-" ++ entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("benchmarks/" ++ entry[1] ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "ranvier", .module = mod }},
            }),
        });
        ecs_bench.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}
