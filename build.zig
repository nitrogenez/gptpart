const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("gptpart", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
    });
    const library = b.addLibrary(.{
        .root_module = module,
        .name = "gptpart",
    });
    b.installArtifact(library);

    const test_step = b.step("test", "Run unit tests");
    const test_mod = b.addTest(.{ .root_module = module });
    const test_run = b.addRunArtifact(test_mod);

    test_step.dependOn(&test_run.step);
}
