const std = @import("std");

const Resolver = @This();
const Io = std.Io;

hostname: Io.net.HostName,
buffer: [16]Io.net.HostName.LookupResult,
queue: Io.Queue(Io.net.HostName.LookupResult),
started: bool,

pub fn init(url: []const u8) !Resolver {
    const hostname = try Io.net.HostName.init(url);
    return Resolver{
        .hostname = hostname,
        .buffer = undefined,
        .queue = undefined,
        .started = false,
    };
}

pub fn resolve(resolver: *Resolver, io: Io, port: u16) !void {
    resolver.queue = .init(&resolver.buffer);
    try resolver.hostname.lookup(io, &resolver.queue, .{ .port = port });
}

pub fn next(resolver: *Resolver, io: Io) !?Io.net.IpAddress {
    while (true) {
        const result = resolver.queue.getOne(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return null,
        };

        switch (result) {
            .address => |addr| return addr,
            .canonical_name => continue,
        }
    }
}
