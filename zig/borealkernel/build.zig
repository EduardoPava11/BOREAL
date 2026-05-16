const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "borealkernel",
        .linkage = .static,
        .root_module = root_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const dng_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/dng_parse.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "borealkernel", .module = root_module },
            },
        }),
    });
    const run_dng_tests = b.addRunArtifact(dng_tests);

    const lslcd_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/lslcd_synthetic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "borealkernel", .module = root_module },
            },
        }),
    });
    const run_lslcd_tests = b.addRunArtifact(lslcd_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_dng_tests.step);
    test_step.dependOn(&run_lslcd_tests.step);
}
