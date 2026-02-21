const std = @import("std");

const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // addExecutable
    const exe_mod = brk: {
        const vaxis = b.dependency("vaxis", .{
            .target = target,
            .optimize = optimize,
        });

        var exe_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            },
        });
        exe_mod = addDependencies(b, target, exe_mod);
        const exe = b.addExecutable(.{
            .name = "player",
            .root_module = exe_mod,
        });
        b.installArtifact(exe);

        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        // Run from installation directory rather than directly from within the cache directory.
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        break :brk exe_mod;
    };

    // Tests
    {
        const mod_tests = b.addTest(.{
            .name = "test",
            .root_module = addDependencies(b, target, b.createModule(.{
                .root_source_file = b.path("src/tests.zig"),
                .target = target,
            })),
        });
        const run_mod_tests = b.addRunArtifact(mod_tests);
        const exe_tests = b.addTest(.{
            .root_module = exe_mod,
        });
        const run_exe_tests = b.addRunArtifact(exe_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_exe_tests.step);
    }
}

pub fn addDependencies(b: *Build, target: Build.ResolvedTarget, mod: *Build.Module) *Build.Module {
    mod.addIncludePath(b.path("vendor/miniaudio"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/miniaudio/miniaudio.c"),
        // .flags = &.{"-DMINIAUDIO_IMPLEMENTATION"},
    });
    mod.link_libc = true;
    if (target.result.os.tag == .macos) {
        mod.linkFramework("CoreAudio", .{});
        mod.linkFramework("CoreFoundation", .{});
        mod.linkFramework("AudioUnit", .{});
    }

    return mod;
}
