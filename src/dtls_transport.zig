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
frame_offset: u32 = 0,

pub const DataEvent = union(enum) {
    rtp: []const u8,
    rtcp: []const u8,
    app_data: []const u8,
};

pub const Config = struct {
    random: std.Random,
};

pub const InitError = std.mem.Allocator.Error || dtls.Session.InitError || error{CertificateGenerationFailed};

pub fn init(io: Io, allocator: std.mem.Allocator, config: Config) InitError!DtlsTransport {
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
    const certificate = utils.generateP256KeyPairDer(io, &der_buffer) catch return error.CertificateGenerationFailed;

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

pub const ApplyIceAttributesError = std.mem.Allocator.Error || error{InvalidSDP};

pub fn applyIceAttributes(transport: *DtlsTransport, media: *SDPSession.Media, fingerprint: *const [32]u8, now: i64) ApplyIceAttributesError!void {
    Logger.debug("Apply remote credentials and candidates...", .{});
    const remote_credens = transport.ice_agent.getRemoteCredentials();
    if (remote_credens) |credens| {
        if (!std.mem.eql(u8, media.ice_ufrag, credens.username) or !std.mem.eql(u8, media.ice_pwd, credens.password))
            return error.InvalidSDP;
    } else {
        transport.ice_agent.setRemoteCredentials(
            .{ .username = media.ice_ufrag, .password = media.ice_pwd },
            now,
        ) catch |err| switch (err) {
            error.CredentialsTooLong => return error.InvalidSDP,
            error.OutOfMemory => |e| return e,
        };

        for (media.candidates) |candidate| {
            if (candidate.component != 1 or candidate.transport == .tcp) continue;
            try transport.ice_agent.addRemoteCandidate(candidate, now);
        }

        transport.session.setRole(media.setup == .active) catch |err| {
            Logger.err("Failed to setup dtls session: {}", .{err});
            transport.session.fail();
        };
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

pub fn addIceServer(transport: *DtlsTransport, addr: Io.net.IpAddress, server: ice.agent.Server, now: i64) !void {
    try transport.ice_agent.addServer(addr, server, now);
}

pub const WriteMediaError = std.mem.Allocator.Error || error{WriteFailed};
pub const WriteAppDataError = error{WriteFailed};

/// Minimum size of the buffers passed to the write functions. STUN messages are not subject to it.
///
/// Largest packet is a DTLS record at the 1237 bytes DTLS MTU (1200 bytes SCTP packet with AES-GCM
/// expansion; RTP is at most 1232 bytes: 12 header + 8 mid extension + 2 RTX + 1200 payload + 10
/// SRTP tag, RTCP 1214), plus 48 bytes for an IPv6 TURN send indication header and 3 bytes of
/// padding.
pub const min_write_buffer_size = 1288;

/// Returns the part of `buffer` packets must be written to, after the TURN header when the
/// nominated pair is relayed.
pub fn payloadBuffer(transport: *const DtlsTransport, buffer: []u8) error{WriteFailed}![]u8 {
    if (buffer.len < min_write_buffer_size) return error.WriteFailed;
    return buffer[transport.frame_offset..];
}

/// Same as `payloadBuffer`, with room left at the end for the SRTP overhead and TURN padding.
pub fn rtpPayloadBuffer(transport: *const DtlsTransport, buffer: []u8) error{WriteFailed}![]u8 {
    const payload = try transport.payloadBuffer(buffer);
    const turn_padding: usize = if (transport.frame_offset != 0) 3 else 0;
    const tail = transport.out_srtp_session.?.rtpOverhead() + turn_padding;
    if (payload.len < tail) return error.WriteFailed;
    return payload[0 .. payload.len - tail];
}

pub fn writeRtp(transport: *DtlsTransport, buffer: []u8, len: usize) WriteMediaError!webrtc.TransportMessage {
    const payload = try transport.payloadBuffer(buffer);
    const data = transport.out_srtp_session.?.encryptRtp(
        transport.allocator,
        payload[0..len],
        payload,
    ) catch |err| switch (err) {
        error.MalformedPacket => unreachable,
        else => |e| return e,
    };
    return transport.frame(buffer, data);
}

pub fn writeRtcp(transport: *DtlsTransport, buffer: []u8, len: usize) WriteMediaError!webrtc.TransportMessage {
    const payload = try transport.payloadBuffer(buffer);
    const data = transport.out_srtp_session.?.encryptRtcp(
        transport.allocator,
        payload[0..len],
        payload,
    ) catch |err| switch (err) {
        error.MalformedPacket => unreachable,
        else => |e| return e,
    };
    return transport.frame(buffer, data);
}

pub fn writeAppData(transport: *DtlsTransport, data: []const u8, buffer: []u8) WriteAppDataError!webrtc.TransportMessage {
    const payload = try transport.payloadBuffer(buffer);
    const size = try transport.session.handleWrite(data, payload);
    return transport.frame(buffer, payload[0..size]);
}

pub fn handleRead(transport: *DtlsTransport, message: webrtc.TransportMessage, now: i64, buffer: []u8) !?DataEvent {
    const result = try transport.ice_agent.handleRead(
        .{ .data = message.data, .from = message.from, .to = message.to },
        now,
    );

    const event = switch (result) {
        .app_data => |app_data| blk: {
            const offset = @intFromPtr(app_data.ptr) - @intFromPtr(message.data.ptr);
            const packet = @constCast(message.data)[offset..][0..app_data.len];
            break :blk try transport.handleIceData(now, packet, buffer);
        },
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

pub fn pollTransmit(transport: *DtlsTransport, buffer: []u8) error{WriteFailed}!?webrtc.TransportMessage {
    const ice_msg = (try transport.ice_agent.pollTransmit(buffer)) orelse {
        if (transport.ice_agent.nominated_pair == null) return null;
        const dtls_msg = (try transport.session.pollTransmit(try transport.payloadBuffer(buffer))) orelse return null;
        return try transport.frame(buffer, dtls_msg);
    };

    return .{ .data = ice_msg.data, .from = ice_msg.from, .to = ice_msg.to };
}

pub fn pollTimeout(transport: *DtlsTransport) ?i64 {
    const ice_deadline = transport.ice_agent.pollTimeout() orelse return transport.session.pollTimeout();
    const dtls_deadline = transport.session.pollTimeout() orelse return ice_deadline;
    return @min(ice_deadline, dtls_deadline);
}

// Write TURN header if the nominated pair is relayed, otherwise return the payload as is.
fn frame(transport: *DtlsTransport, buffer: []u8, payload: []const u8) error{WriteFailed}!webrtc.TransportMessage {
    std.debug.assert(payload.ptr == buffer[transport.frame_offset..].ptr);
    const msg = try transport.ice_agent.handleWrite(buffer, payload.len);
    return .{ .data = msg.data, .from = msg.from, .to = msg.to };
}

fn drainEvents(transport: *DtlsTransport, now: i64) std.mem.Allocator.Error!void {
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
        .nominated => {
            transport.frame_offset, _ = transport.ice_agent.getDataFrameSize(0);
        },
    };

    while (transport.session.pollEvent()) |event| switch (event) {
        .connection_state => |state| try transport.events.pushBack(transport.allocator, .{ .dtls_connection_state = state }),
        .srtp_keying_material => |keying| transport.initSrtpSessions(&keying) catch |err| {
            Logger.err("Failed to init srtp sessions: {}", .{err});
            transport.session.fail();
        },
    };
}

fn initSrtpSessions(transport: *DtlsTransport, keying: *const dtls.SrtpProfile) error{InvalidKeyingMaterial}!void {
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
}

fn handleIceData(transport: *DtlsTransport, now: i64, data: []u8, buffer: []u8) !?DataEvent {
    switch (getPacketType(data)) {
        .dtls => {
            const result = transport.session.handleRead(data, now, buffer) catch |err| {
                Logger.debug("Discarding dtls record: {}", .{err});
                return null;
            };
            switch (result) {
                .app_data => |app_data| return .{ .app_data = app_data },
                .consumed => return null,
            }
        },
        .rtp => if (transport.in_srtp_session) |*srtp_session| {
            const rtp_packet = try srtp_session.decryptRtp(transport.allocator, data, data);
            return .{ .rtp = rtp_packet };
        },
        .rtcp => if (transport.in_srtp_session) |*srtp_session| {
            const rtcp_packet = try srtp_session.decryptRtcp(transport.allocator, data, data);
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
