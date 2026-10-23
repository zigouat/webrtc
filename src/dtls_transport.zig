const std = @import("std");
const stun = @import("stun");
const ice = @import("ice");
const rtp = @import("rtp");
const srtp = @import("srtp");
const webrtc = @import("webrtc.zig");
const dtls = @import("dtls/dtls.zig");
const utils = @import("utils.zig");
const SDPSession = @import("sdp_session.zig");

const DtlsTransport = @This();
const Io = std.Io;
const Logger = std.log.scoped(.dtls_transport);
const IceAgent = ice.agent.Agent(.{});

const max_message_size = 1500;
const PacketType = enum { rtp, rtcp, dtls, unknown };

pub const SendError = srtp.EncryptError || std.Io.net.Socket.SendError || error{ WriteFailed, UnknownAttribute };

pub const Event = union(enum) {
    ice_connection_state: ice.ConnectionState,
    ice_candidate: u8,
    end_of_candidates: void,
    ice_gathering_state: ice.GatheringState,
    dtls_connection_state: dtls.ConnectionState,
};

allocator: std.mem.Allocator,
ice_agent: IceAgent,
session: dtls.Session,
in_srtp_session: ?srtp.Session = null,
out_srtp_session: ?srtp.Session = null,
events: std.Deque(Event) = .empty,
nominated_pair: ?struct { *const Io.net.IpAddress, *const Io.net.IpAddress } = null,

pub const DataEvent = union(enum) {
    rtp: []const u8,
    rtcp: []const u8,
    app_data: []const u8,
};

pub const Config = struct {
    random: std.Random,
};

pub fn init(io: Io, allocator: std.mem.Allocator, config: Config) !DtlsTransport {
    var ice_user: [8]u8 = undefined;
    var ice_pwd: [24]u8 = undefined;

    utils.randString(config.random, &ice_user);
    utils.randPassword(config.random, &ice_pwd);

    // Ice credentials are copied into the agent
    var ice_agent = IceAgent.init(allocator, .{
        .credentials = .{ .username = ice_user[0..], .password = ice_pwd[0..] },
        .role = .controlling,
        .random = config.random,
    }) catch return error.OutOfMemory;
    errdefer ice_agent.deinit();

    var der_buffer: [256]u8 = @splat(0);
    const certificate = try utils.generateP256KeyPairDer(io, &der_buffer);

    return .{
        .allocator = allocator,
        .ice_agent = ice_agent,
        .session = try dtls.Session.init(config.random, .{ .key_pair = certificate }),
    };
}

pub fn deinit(transport: *DtlsTransport) void {
    transport.ice_agent.deinit();
    transport.session.deinit();
    transport.events.deinit(transport.allocator);

    if (transport.in_srtp_session) |*srtp_sess| {
        srtp_sess.deinit(transport.allocator);
        transport.in_srtp_session = null;
    }

    if (transport.out_srtp_session) |*srtp_sess| {
        srtp_sess.deinit(transport.allocator);
        transport.out_srtp_session = null;
    }
}

pub fn applyIceAttributes(transport: *DtlsTransport, media: *SDPSession.Media, fingerprint: *const [32]u8, now: i64) !void {
    Logger.debug("Apply remote credentials and candidates...", .{});
    const remote_credens = transport.ice_agent.getRemoteCredentials();
    if (remote_credens) |credens| {
        if (!std.mem.eql(u8, media.ice_ufrag, credens.username) or !std.mem.eql(u8, media.ice_pwd, credens.password))
            return error.MismatchedIceCredentials;
    } else {
        try transport.ice_agent.setRemoteCredentials(
            .{ .username = media.ice_ufrag, .password = media.ice_pwd },
            now,
        );

        for (media.candidates) |candidate| {
            if (candidate.component != 1 or candidate.transport == .tcp) continue;
            try transport.ice_agent.addRemoteCandidate(candidate, now);
        }

        try transport.session.setRole(media.setup == .active);
        try transport.drainEvents(now);
    }

    transport.session.setPeerFingerprint(fingerprint);
}

pub fn getConnectionState(transport: *const DtlsTransport) struct { ice.ConnectionState, dtls.ConnectionState } {
    return .{ transport.ice_agent.connection_state, transport.session.connection_state };
}

pub fn close(transport: *DtlsTransport) void {
    transport.session.close();
    transport.ice_agent.close();
}

pub fn getRole(transport: *const DtlsTransport) dtls.Role {
    return transport.session.getRole();
}

pub fn addIceLocalAddrs(transport: *DtlsTransport, addrs: []const Io.net.IpAddress, now: i64) !void {
    try transport.ice_agent.addLocalAddrs(addrs, now);
    try transport.drainEvents(now);
}

pub fn addIceStunServer(transport: *DtlsTransport, addr: Io.net.IpAddress, stun_server: Io.net.IpAddress) !void {
    try transport.ice_agent.addStunServer(addr, stun_server);
}

pub fn addIceTurnServer(
    transport: *DtlsTransport,
    addr: Io.net.IpAddress,
    turn_server: Io.net.IpAddress,
    username: []const u8,
    password: []const u8,
) !void {
    try transport.ice_agent.addTurnServer(addr, turn_server, username, password);
}

/// Encrypts the RTP packet in `buffer[0..len]` in place.
pub fn writeRtp(transport: *DtlsTransport, buffer: []u8, len: usize) !webrtc.TransportMessage {
    const data = try transport.out_srtp_session.?.encryptRtp(transport.allocator, buffer[0..len], buffer);
    return transport.toTransportMessage(data);
}

/// Encrypts the RTCP packet in `buffer[0..len]` in place.
pub fn writeRtcp(transport: *DtlsTransport, buffer: []u8, len: usize) !webrtc.TransportMessage {
    const data = try transport.out_srtp_session.?.encryptRtcp(transport.allocator, buffer[0..len], buffer);
    return transport.toTransportMessage(data);
}

pub fn writeAppData(transport: *DtlsTransport, data: []const u8, buffer: []u8) webrtc.TransportMessage {
    const size = transport.session.handleWrite(data, buffer);
    return transport.toTransportMessage(buffer[0..size]);
}

fn toTransportMessage(transport: *const DtlsTransport, data: []const u8) webrtc.TransportMessage {
    const from, const to = transport.nominated_pair.?;
    return .{ .data = data, .from = from, .to = to };
}

pub fn handleRead(transport: *DtlsTransport, message: webrtc.TransportMessage, now: i64, buffer: []u8) !?DataEvent {
    const result = try transport.ice_agent.handleRead(
        .{ .data = message.data, .from = message.from, .to = message.to },
        now,
    );

    const event = switch (result) {
        .app_data => |app_data| try transport.handleIceData(now, app_data, buffer),
        .consumed => null,
    };

    // Always drain events, data may be bundled with handshake messages.
    try transport.drainEvents(now);
    return event;
}

pub fn handleTimeout(transport: *DtlsTransport, now: i64) !void {
    try transport.ice_agent.handleTimeout(now);
    if (transport.session.connection_state != .new) transport.session.handleTimeout(now);
    try transport.drainEvents(now);
}

pub fn pollEvent(transport: *DtlsTransport) ?Event {
    return transport.events.popFront();
}

pub fn pollTransmit(transport: *DtlsTransport, buffer: []u8) ?webrtc.TransportMessage {
    const ice_msg = (transport.ice_agent.pollTransmit(buffer) catch return null) orelse {
        const from, const to = transport.nominated_pair orelse return null;
        const dtls_msg = transport.session.pollTransmit(buffer) orelse return null;
        return .{ .data = dtls_msg, .from = from, .to = to };
    };

    return .{ .data = ice_msg.data, .from = ice_msg.from, .to = ice_msg.to };
}

pub fn pollTimeout(transport: *DtlsTransport) ?i64 {
    const ice_deadline = transport.ice_agent.pollTimeout() orelse return transport.session.pollTimeout();
    const dtls_deadline = transport.session.pollTimeout() orelse return ice_deadline;
    return @min(ice_deadline, dtls_deadline);
}

fn drainEvents(transport: *DtlsTransport, now: i64) !void {
    while (transport.ice_agent.pollEvent()) |event| switch (event) {
        .connection_state => |state| {
            if (state == .connected) transport.session.handleTimeout(now);
            try transport.events.pushBack(transport.allocator, .{ .ice_connection_state = state });
        },
        .candidate => |range| for (range.@"0"..range.@"1" + 1) |idx| {
            try transport.events.pushBack(transport.allocator, .{ .ice_candidate = @intCast(idx) });
        },
        .gathering_state => |state| {
            if (state == .complete) try transport.events.pushBack(transport.allocator, .end_of_candidates);
            try transport.events.pushBack(transport.allocator, .{ .ice_gathering_state = state });
        },
        .nominated => |pair| transport.nominated_pair = .{
            &transport.ice_agent.candidates[pair.local].base,
            &transport.ice_agent.remote_candidates[pair.remote].address,
        },
    };

    while (transport.session.pollEvent()) |event| switch (event) {
        .connection_state => |state| try transport.events.pushBack(transport.allocator, .{ .dtls_connection_state = state }),
        .srtp_keying_material => |keying| {
            const profile = switch (keying.profile) {
                1 => srtp.Profile.AesCm128HmacSha1_80,
                2 => srtp.Profile.AesCm128HmacSha1_32,
                else => unreachable,
            };

            transport.in_srtp_session = try srtp.Session.init(&keying.remote_keying_material, profile);
            errdefer {
                transport.in_srtp_session.?.deinit(transport.allocator);
                transport.in_srtp_session = null;
            }

            transport.out_srtp_session = try srtp.Session.init(&keying.local_keying_material, profile);
        },
    };
}

fn handleIceData(transport: *DtlsTransport, now: i64, data: []const u8, buffer: []u8) !?DataEvent {
    switch (getPacketType(data)) {
        .dtls => {
            switch (try transport.session.handleRead(data, now, buffer)) {
                .app_data => |app_data| return .{ .app_data = app_data },
                .consumed => return null,
            }
        },
        .rtp => if (transport.in_srtp_session) |*srtp_session| {
            const buffer2 = @constCast(data.ptr[0..max_message_size]);
            const rtp_packet = try srtp_session.decryptRtp(transport.allocator, data, buffer2);
            return .{ .rtp = rtp_packet };
        },
        .rtcp => if (transport.in_srtp_session) |*srtp_session| {
            const buffer2 = @constCast(data.ptr[0..max_message_size]);
            const rtcp_packet = try srtp_session.decryptRtcp(transport.allocator, data, buffer2);
            return .{ .rtcp = rtcp_packet };
        },
        .unknown => Logger.debug("Received unknown packet", .{}),
    }

    return null;
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
