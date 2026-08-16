const std = @import("std");
const ice = @import("ice");
const rtp = @import("rtp");
const srtp = @import("srtp");
const dtls = @import("dtls/dtls.zig");
const SDPSession = @import("sdp_session.zig");

const DtlsTransport = @This();
const Logger = std.log.scoped(.dtls_transport);

const PacketType = enum { rtp, rtcp, dtls, unknown };

const Timer = struct {
    group: std.Io.Group,
    int_timer_expired: bool,
    final_timer_expired: bool,

    const empty = Timer{
        .group = .init,
        .int_timer_expired = false,
        .final_timer_expired = false,
    };
};

pub const SendError = srtp.EncryptError || std.Io.net.Socket.SendError || error{ WriteFailed, UnknownAttribute };

allocator: std.mem.Allocator,
ice_agent: ice.Agent,
session: dtls.Session,
in_srtp_session: ?srtp.Session = null,
out_srtp_session: ?srtp.Session = null,
timer: Timer = .empty,
mutex: std.Io.Mutex = .init,

on_data: *const fn (transport: *DtlsTransport, DataEvent) void,
on_event: *const fn (transport: *DtlsTransport, Event) void,

pub const Event = union(enum) {
    ice_connection_state: ice.ConnectionState,
    ice_candidate: ?ice.Candidate,
    ice_gathering_state: ice.GatheringState,
    dtls_connection_state: dtls.ConnectionState,
};

pub const DataEvent = union(enum) {
    rtp: []const u8,
    rtcp: []const u8,
    app_data: []const u8,
};

pub const Config = struct {
    ice_servers: []const ice.IceServer = &.{},
    on_data: *const fn (*DtlsTransport, DataEvent) void,
    on_event: *const fn (*DtlsTransport, Event) void,
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, config: Config) !DtlsTransport {
    var ice_agent: ice.Agent = try .init(io, allocator, .{
        .ice_servers = config.ice_servers,
        .on_data = onIceData,
        .on_event = onIceEvent,
    });
    errdefer ice_agent.deinit();

    const pair = try dtls.P256KeyPair.init(io);
    var der_buffer: [256]u8 = @splat(0);
    const der = try pair.toDer(&der_buffer);

    return .{
        .allocator = allocator,
        .ice_agent = ice_agent,
        .session = try .init(io, .{
            .key_pair = der,
            .on_send_data = onDtlsSendData,
            .on_set_timer = setDtlsTimer,
            .on_get_timer_state = getDtlsTimerState,
        }),
        .on_data = config.on_data,
        .on_event = config.on_event,
    };
}

pub fn deinit(transport: *DtlsTransport) void {
    transport.ice_agent.deinit();
    transport.session.deinit();

    if (transport.in_srtp_session) |*srtp_sess| {
        srtp_sess.deinit();
        transport.in_srtp_session = null;
    }

    if (transport.out_srtp_session) |*srtp_sess| {
        srtp_sess.deinit();
        transport.out_srtp_session = null;
    }
}

pub fn getIo(transport: *const DtlsTransport) std.Io {
    return transport.ice_agent.io;
}

pub fn setPeerFingerprint(transport: *DtlsTransport, fingerprint: *const [32]u8) void {
    transport.session.setPeerFingerprint(fingerprint);
}

pub fn applyIceAttributes(transport: *DtlsTransport, media: *SDPSession.Media) !void {
    Logger.debug("Apply remote credentials and candidates...", .{});
    const remote_credens = transport.ice_agent.remoteCredentials();
    if (remote_credens) |credens| {
        if (!std.mem.eql(u8, media.ice_ufrag, credens.username) or !std.mem.eql(u8, media.ice_pwd, credens.password))
            return error.MismatchedIceCredentials;
    } else {
        try transport.ice_agent.setRemoteCredentials(.{ .username = media.ice_ufrag, .password = media.ice_pwd });

        for (media.candidates) |candidate| {
            if (candidate.component != 1 or candidate.transport == .tcp) continue;
            try transport.ice_agent.addRemoteCandidate(candidate);
        }

        try transport.session.setRole(media.setup == .active);
    }
}

pub fn gatherCandidates(transport: *DtlsTransport, role: ice.Role) !void {
    try transport.ice_agent.setRole(role);
    try transport.ice_agent.gatherCandidates();
}

pub fn getConnectionState(transport: *const DtlsTransport) struct { ice.ConnectionState, dtls.ConnectionState } {
    return .{ transport.ice_agent.connectionState(), transport.session.connection_state };
}

pub fn sendRtp(transport: *DtlsTransport, data: []const u8) SendError!void {
    if (transport.session.connection_state != .connected) return;
    const buffer = try transport.ice_agent.createPacket();
    defer transport.ice_agent.destroyPacket(buffer);
    const encrypted = try transport.out_srtp_session.?.encryptRtp(data, buffer);
    try transport.ice_agent.sendData(encrypted);
}

pub fn sendRtcp(transport: *DtlsTransport, data: []const u8) SendError!void {
    if (transport.session.connection_state != .connected) return;
    const buffer = try transport.ice_agent.createPacket();
    defer transport.ice_agent.destroyPacket(buffer);
    const encrypted = try transport.out_srtp_session.?.encryptRtcp(data, buffer);
    try transport.ice_agent.sendData(encrypted);
}

pub fn sendData(transport: *DtlsTransport, data: []const u8) !void {
    const buffer = try transport.ice_agent.createPacket();
    defer transport.ice_agent.destroyPacket(buffer);
    try transport.session.writeData(data);
}

pub fn close(transport: *DtlsTransport) void {
    transport.session.close();
    transport.ice_agent.close();
}

fn onIceData(_: ?*anyopaque, ice_agent: *ice.Agent, data: []const u8) std.Io.Cancelable!void {
    const transport: *DtlsTransport = @alignCast(@fieldParentPtr("ice_agent", ice_agent));
    transport.handleIceData(data) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => Logger.warn("Error while handling ice message: {}", .{err}),
    };
}

fn handleIceData(transport: *DtlsTransport, data: []const u8) !void {
    switch (getPacketType(data)) {
        .dtls => switch (transport.session.connection_state) {
            .new => {},
            else => {
                transport.handleDtlsData(data) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.WantData => {},
                    else => |e| {
                        transport.on_event(transport, .{ .dtls_connection_state = transport.session.connection_state });
                        return e;
                    },
                };
                transport.on_event(transport, .{ .dtls_connection_state = transport.session.connection_state });
            },
        },
        .rtp => if (transport.in_srtp_session) |*srtp_session| {
            const buffer = try transport.ice_agent.createPacket();
            defer transport.ice_agent.destroyPacket(buffer);
            const rtp_packet = try srtp_session.decryptRtp(data, buffer);
            transport.on_data(transport, .{ .rtp = rtp_packet });
        },
        .rtcp => if (transport.in_srtp_session) |*srtp_session| {
            const buffer = try transport.ice_agent.createPacket();
            defer transport.ice_agent.destroyPacket(buffer);
            const rtcp_packet = try srtp_session.decryptRtcp(data, buffer);
            transport.on_data(transport, .{ .rtcp = rtcp_packet });
        },
        .unknown => Logger.debug("Received unknown packet", .{}),
    }
}

fn onIceEvent(_: ?*anyopaque, ice_agent: *ice.Agent, event: ice.Agent.Event) std.Io.Cancelable!void {
    const transport: *DtlsTransport = @alignCast(@fieldParentPtr("ice_agent", ice_agent));
    switch (event) {
        .gathering_state => |state| transport.on_event(transport, .{ .ice_gathering_state = state }),
        .connection_state => |state| {
            if (state == .connected) {
                transport.on_event(transport, .{ .ice_connection_state = state });
                return .{ .ice_connection_state = state };
            }
        },
        .gathering_state => |gathering_state| return .{ .ice_gathering_state = gathering_state },
        .data => |ice_data| {
            defer transport.ice_agent.destroyPacket(ice_data);
            switch (getPacketType(ice_data)) {
                .dtls => {
                    const current_state = transport.session.connection_state;
                    const data = transport.handleDtlsData(ice_data) catch |err| switch (err) {
                        error.WantData => continue,
                        else => |e| {
                            Logger.err("Error occurred while handling dtls message: {}", .{e});
                            return .{ .dtls_connection_state = transport.session.connection_state };
                        },
                    };

                    return if (data) |d| .{ .app_data = d } else blk: {
                        if (current_state != transport.session.connection_state) {
                            break :blk .{ .dtls_connection_state = transport.session.connection_state };
                        } else {
                            continue;
                        }
                    };
                },
                .rtp => {
                    switch (transport.session.connection_state) {
                        .connected => return .{
                            .rtp = try transport.in_srtp_session.?.decryptRtp(
                                ice_data,
                                try transport.ice_agent.createPacket(),
                            ),
                        },
                        else => continue,
                    }
                },
                .rtcp => switch (transport.session.connection_state) {
                    .connected => return .{
                        .rtcp = try transport.in_srtp_session.?.decryptRtcp(
                            ice_data,
                            try transport.ice_agent.createPacket(),
                        ),
                    },
                    else => continue,
                },
                .unknown => Logger.debug("Received unknown packet", .{}),
            }
        },
        .candidate => |candidate| transport.on_event(transport, .{ .ice_candidate = candidate }),
        else => {},
    }
}

fn onDtlsSendData(dtls_session: *dtls.Session, data: []const u8) i32 {
    const transport: *DtlsTransport = @alignCast(@fieldParentPtr("session", dtls_session));
    transport.ice_agent.sendData(data) catch |err| {
        Logger.err("send data on ice agent failed: {}", .{err});
        return 0;
    };

    return @intCast(data.len);
}

fn getDtlsTimerState(dtls_session: *dtls.Session) i32 {
    Logger.debug("Get dtls timer state", .{});
    const transport: *DtlsTransport = @alignCast(@fieldParentPtr("session", dtls_session));
    const timer = &transport.timer;
    return if (timer.int_timer_expired and timer.final_timer_expired) 2 else if (timer.int_timer_expired) 1 else 0;
}

fn setDtlsTimer(dtls_session: *dtls.Session, int_ms: u32, fin_ms: u32) void {
    Logger.debug("Set dtls timer: int={}ms fin={}ms", .{ int_ms, fin_ms });
    const transport: *DtlsTransport = @alignCast(@fieldParentPtr("session", dtls_session));
    const timer = &transport.timer;
    const io = transport.getIo();

    timer.group.cancel(io);
    timer.* = .empty;

    if (fin_ms != 0) {
        timer.group.concurrent(io, handleIntTimeout, .{ transport, int_ms }) catch return;
        timer.group.concurrent(io, handleFinTimeout, .{ transport, fin_ms }) catch return;
    }
}

fn handleIntTimeout(transport: *DtlsTransport, time_ms: u32) !void {
    try transport.getIo().sleep(.fromMilliseconds(time_ms), .awake);
    transport.timer.int_timer_expired = true;
}

fn handleFinTimeout(transport: *DtlsTransport, time_ms: u32) !void {
    const io = transport.getIo();
    try io.sleep(.fromMilliseconds(time_ms), .awake);

    try transport.mutex.lock(io);
    defer transport.mutex.unlock(io);
    transport.timer.final_timer_expired = true;
    _ = transport.session.handleData(null, &.{}) catch |err| switch (err) {
        error.WantData => {},
        else => |e| Logger.err("Error occurred while handling dtls message: {}", .{e}),
    };
}

fn handleDtlsData(transport: *DtlsTransport, data: []const u8) !?[]const u8 {
    try transport.mutex.lock(transport.getIo());
    defer transport.mutex.unlock(transport.getIo());

    const out_data = try transport.ice_agent.createPacket();
    errdefer transport.ice_agent.destroyPacket(out_data);

    const result = try transport.session.handleData(data, out_data);
    errdefer transport.session.connection_state = .failed;

    // TODO: don't set connection state of dtls until we create the whole srtp session.
    // Otherwise, we might start receiving RTP/RTCP packets before we have the srtp session ready.
    if (transport.in_srtp_session == null) {
        const srtp_profile = try transport.session.exportSrtpKeyingMaterial();
        const profile = switch (srtp_profile.profile) {
            1 => srtp.Profile.AesCm128HmacSha1_80,
            2 => srtp.Profile.AesCm128HmacSha1_32,
            else => unreachable,
        };

        transport.in_srtp_session = try srtp.Session.init(transport.getIo(), transport.allocator, &srtp_profile.remote_keying_material, profile);
        errdefer {
            transport.in_srtp_session.?.deinit();
            transport.in_srtp_session = null;
        }
        transport.out_srtp_session = try srtp.Session.init(transport.getIo(), transport.allocator, &srtp_profile.local_keying_material, profile);
    }

    return if (result) |buffer| buffer else blk: {
        transport.ice_agent.destroyPacket(out_data);
        break :blk null;
    };
}

fn getPacketType(data: []const u8) PacketType {
    if (data.len < 2) {
        @branchHint(.cold);
        return .unknown;
    }

    return switch (data[0]) {
        20...63 => .dtls,
        128...191 => switch (data[1]) {
            192...223 => .rtcp,
            else => .rtp,
        },
        else => .unknown,
    };
}
