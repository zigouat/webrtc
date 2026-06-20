const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize });
    const mbedtls = b.dependency("mbedtls", .{ .target = target, .optimize = optimize });

    const mbedtls_artifact = mbedtls.artifact("mbedtls");
    mbedtls_artifact.root_module.addCMacro("MBEDTLS_CONFIG_FILE", "\"config.h\"");
    mbedtls_artifact.root_module.addIncludePath(b.path("src/dtls"));

    const mod = b.addModule("webrtc", .{
        .root_source_file = b.path("src/webrtc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdp", .module = protocols.module("sdp") },
            .{ .name = "ice", .module = protocols.module("ice") },
            .{ .name = "rtp", .module = protocols.module("rtp") },
            .{ .name = "rtcp", .module = protocols.module("rtcp") },
            .{ .name = "srtp", .module = protocols.module("srtp") },
        },
    });

    mod.linkLibrary(mbedtls_artifact);
    mod.addIncludePath(b.path("src/dtls"));

    {
        const mod_tests = b.addTest(.{ .root_module = mod });
        const run_mod_tests = b.addRunArtifact(mod_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
    }
}
