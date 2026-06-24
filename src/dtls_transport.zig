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

allocator: std.mem.Allocator,
ice_agent: ice.Agent,
session: dtls.Session,
in_srtp_session: ?srtp.Session = null,
out_srtp_session: ?srtp.Session = null,
timer: Timer = .empty,

pub const Event = union(enum) {
    ice_connection_state: ice.ConnectionState,
    ice_candidate: ?ice.Candidate,
    dtls_connection_state: dtls.ConnectionState,
    rtp: []const u8,
    rtcp: []const u8,
};

pub const Config = struct {};

pub fn init(io: std.Io, allocator: std.mem.Allocator, _: Config) !DtlsTransport {
    var ice_agent: ice.Agent = try .init(io, allocator, .{});
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
    };
}

pub fn deinit(transport: *DtlsTransport) void {
    transport.ice_agent.deinit();
    transport.session.deinit();

    if (transport.in_srtp_session) |*srtp_sess| srtp_sess.deinit();
    if (transport.out_srtp_session) |*srtp_sess| srtp_sess.deinit();
}

pub fn getIo(transport: *const DtlsTransport) std.Io {
    return transport.ice_agent.io;
}

pub fn setPeerFingerprint(transport: *DtlsTransport, fingerprint: *const [32]u8) void {
    transport.session.setPeerFingerprint(fingerprint);
}

pub fn applyIceAttributes(transport: *DtlsTransport, media: *SDPSession.SDPMedia) !void {
    Logger.debug("Apply remote credentials and candidates...", .{});
    const remote_credens = transport.ice_agent.remote_credentials;
    if (remote_credens) |credens| {
        if (!std.mem.eql(u8, media.ice_ufrag, credens.username) or !std.mem.eql(u8, media.ice_pwd, credens.password))
            return error.MismatchedIceCredentials;
    } else {
        try transport.ice_agent.setRemoteCredentials(.{ .username = media.ice_ufrag, .password = media.ice_pwd });

        for (media.candidates) |candidate| {
            if (candidate.component != 1 or candidate.transport == .tcp or std.meta.activeTag(candidate.address) == .ip6) continue;
            try transport.ice_agent.addRemoteCandidate(candidate);
        }

        try transport.session.setRole(media.setup == .active);
    }
}

pub fn gatherCandidates(transport: *DtlsTransport, role: ice.Role) !void {
    transport.ice_agent.setRole(role);
    try transport.ice_agent.gatherCandidates();
}

pub fn getConnectionState(transport: *const DtlsTransport) struct { ice.ConnectionState, dtls.ConnectionState } {
    return .{ transport.ice_agent.connection_state, transport.session.connection_state };
}

pub inline fn sendRtp(transport: *DtlsTransport, data: []const u8) !void {
    const buffer = try transport.ice_agent.createPacket();
    defer transport.ice_agent.destroyPacket(buffer);
    const encrypted = try transport.out_srtp_session.?.encryptRtp(data, buffer);
    try transport.ice_agent.sendData(encrypted);
}

pub fn sendRtcp(transport: *DtlsTransport, data: []const u8) !void {
    const buffer = try transport.ice_agent.createPacket();
    defer transport.ice_agent.destroyPacket(buffer);
    const encrypted = try transport.out_srtp_session.?.encryptRtcp(data, buffer);
    try transport.ice_agent.sendData(encrypted);
}

pub fn poll(transport: *DtlsTransport) !Event {
    while (transport.ice_agent.poll()) |ice_event| switch (ice_event) {
        .candidate => |candidate| return .{ .ice_candidate = candidate },
        .connection_state => |ice_connection_state| {
            if (ice_connection_state == .connected) transport.session.handleData(null) catch {};
            return .{ .ice_connection_state = ice_connection_state };
        },
        .data => |ice_data| {
            defer transport.ice_agent.destroyPacket(ice_data);
            switch (getPacketType(ice_data)) {
                .dtls => switch (transport.session.connection_state) {
                    .new => continue,
                    else => {
                        transport.handleDtlsData(ice_data) catch |err| switch (err) {
                            error.WantData => continue,
                            else => |e| {
                                Logger.err("Error occurred while handling dtls message: {}", .{e});
                                return .{ .dtls_connection_state = transport.session.connection_state };
                            },
                        };
                        return .{ .dtls_connection_state = transport.session.connection_state };
                    },
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
                .unknown => Logger.debug("Received unkown packet", .{}),
            }
        },
    } else |err| return err;
}

pub fn close(transport: *DtlsTransport) void {
    transport.session.close();
    transport.ice_agent.close();
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
    try transport.getIo().sleep(.fromMilliseconds(time_ms), .awake);
    transport.timer.final_timer_expired = true;
    transport.session.handleData(null) catch return;
}

fn handleDtlsData(transport: *DtlsTransport, data: []const u8) !void {
    try transport.session.handleData(data);
    if (transport.in_srtp_session == null) {
        const srtp_profile = try transport.session.exportSrtpKeyingMaterial();
        const profile = switch (srtp_profile.profile) {
            1 => srtp.Profile.AesCm128HmacSha1_80,
            2 => srtp.Profile.AesCm128HmacSha1_32,
            else => unreachable,
        };

        transport.in_srtp_session = try srtp.Session.init(transport.allocator, &srtp_profile.remote_keying_material, profile);
        transport.out_srtp_session = try srtp.Session.init(transport.allocator, &srtp_profile.local_keying_material, profile);
    }
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
