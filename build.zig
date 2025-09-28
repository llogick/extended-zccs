const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information");
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    const mod = b.addModule("extended-zccs", .{
        .root_source_file = b.path("src/mod.zig"),
        .optimize = optimize,
        .target = target,
        .strip = strip,
    });

    const unit_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
