const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const webrtc = b.dependency("webrtc", .{ .target = target, .optimize = optimize });
    const media = b.dependency("media", .{ .target = target, .optimize = optimize });
    const media_formats = b.dependency("media_formats", .{ .target = target, .optimize = optimize });
    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize });

    const apps = &.{
        .{
            .name = "play_from_disk",
            .root_source_file = b.path("play-from-disk/main.zig"),
        },
        .{
            .name = "play_from_disk_renegotiation",
            .root_source_file = b.path("play-from-disk-renegotiation/main.zig"),
        },
        .{
            .name = "reflect",
            .root_source_file = b.path("reflect/main.zig"),
        },
    };

    inline for (apps) |app| {
        const exe = b.addExecutable(.{
            .name = app.name,
            .root_module = b.createModule(.{
                .root_source_file = app.root_source_file,
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "media", .module = media.module("media") },
                    .{ .name = "rtp", .module = protocols.module("rtp") },
                    .{ .name = "webrtc", .module = webrtc.module("webrtc") },
                    .{ .name = "mp4", .module = media_formats.module("mp4") },
                    .{ .name = "ivf", .module = media_formats.module("ivf") },
                },
            }),
        });

        b.installArtifact(exe);

        const run_step = b.step("run-" ++ app.name, "Run the app");

        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }
}
