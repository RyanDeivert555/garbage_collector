const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/gc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "garbage_collector",
        .linkage = .static,
        .root_module = root_mod,
    });

    const win32 = b.dependency("win32", .{});
    lib.root_module.addImport("win32", win32.module("win32"));

    b.installArtifact(lib);

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .imports = &.{
                .{
                    .name = "garbage_collector",
                    .module = root_mod,
                },
            },
        }),
    });
    unit_tests.root_module.linkLibrary(lib);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // TODO: do i need check?
    const check_exe = b.addExecutable(.{
        .name = "garbage_collector",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const check_step = b.step("check", "Compile without emitting binary");
    check_step.dependOn(&check_exe.step);
}
