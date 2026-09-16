const std = @import("std");
const ice = @import("ice");
const rtp = @import("rtp");
const srtp = @import("srtp");
const dtls = @import("dtls/dtls.zig");
const utils = @import("utils.zig");
const SDPSession = @import("sdp_session.zig");
const SocketHandler = @import("io/socket_handler.zig");
const TimerManager = @import("io/timer_manager.zig");
const DnsResolver = @import("io/dns_resolver.zig");

const DtlsTransport = @This();
const Io = std.Io;
const Logger = std.log.scoped(.dtls_transport);
const IceAgent = ice.agent.Agent(.{});

const max_message_size = 1500;
const PacketType = enum { rtp, rtcp, dtls, unknown };

pub const SendError = srtp.EncryptError || std.Io.net.Socket.SendError || error{ WriteFailed, UnknownAttribute };

allocator: std.mem.Allocator,
io: Io,
memory_pool: std.heap.MemoryPool([max_message_size]u8),
timer_manager: TimerManager,
socket_handler: SocketHandler,
prng: *std.Random.DefaultCsprng,
mutex: std.Io.Mutex = .init,
group: Io.Group = .init,

ice_servers: []const ice.IceServer,
ice_agent: IceAgent,
session: dtls.Session,
in_srtp_session: ?srtp.Session = null,
out_srtp_session: ?srtp.Session = null,

socket: *Io.net.Socket = undefined,
dest: Io.net.IpAddress = undefined,
current_deadline: i64 = std.math.maxInt(i64),

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
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&seed);

    const prng = try allocator.create(std.Random.DefaultCsprng);
    prng.* = .init(seed);
    errdefer allocator.destroy(prng);

    var credens = try ice.Credentials.generate(io, allocator);
    defer credens.deinit(allocator);

    var ice_agent = try IceAgent.init(allocator, .{
        .credentials = credens,
        .role = .controlling,
        .random = prng.random(),
    });
    errdefer ice_agent.deinit();

    var der_buffer: [256]u8 = @splat(0);
    const certificate = try utils.generateP256KeyPairDer(io, &der_buffer);

    return .{
        .allocator = allocator,
        .io = io,
        .prng = prng,
        .memory_pool = .empty,
        .ice_servers = config.ice_servers,
        .socket_handler = .init(),
        .timer_manager = .{},
        .ice_agent = ice_agent,
        .session = try dtls.Session.init(prng.random(), .{ .key_pair = certificate }),
        .on_data = config.on_data,
        .on_event = config.on_event,
    };
}

pub fn deinit(transport: *DtlsTransport) void {
    transport.group.cancel(transport.io);
    transport.timer_manager.deinit(transport.allocator);
    transport.socket_handler.deinit(transport.io, transport.allocator);

    transport.allocator.destroy(transport.prng);
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

    transport.memory_pool.deinit(transport.allocator);
}

pub fn getIo(transport: *const DtlsTransport) std.Io {
    return transport.io;
}

pub fn setPeerFingerprint(transport: *DtlsTransport, fingerprint: *const [32]u8) void {
    transport.session.setPeerFingerprint(fingerprint);
}

pub fn applyIceAttributes(transport: *DtlsTransport, media: *SDPSession.Media) !void {
    Logger.debug("Apply remote credentials and candidates...", .{});
    const remote_credens = transport.ice_agent.getRemoteCredentials();
    if (remote_credens) |credens| {
        if (!std.mem.eql(u8, media.ice_ufrag, credens.username) or !std.mem.eql(u8, media.ice_pwd, credens.password))
            return error.MismatchedIceCredentials;
    } else {
        const now = Io.Timestamp.now(transport.io, .awake).toMilliseconds();
        try transport.ice_agent.setRemoteCredentials(
            .{ .username = media.ice_ufrag, .password = media.ice_pwd },
            now,
        );

        for (media.candidates) |candidate| {
            if (candidate.component != 1 or candidate.transport == .tcp) continue;
            try transport.ice_agent.addRemoteCandidate(candidate, now);
        }

        try transport.session.setRole(media.setup == .active);

        try transport.drainIceEvents();
    }
}

pub fn gatherCandidates(transport: *DtlsTransport, role: ice.Role) !void {
    transport.ice_agent.role = role;
    var it = try ice.IfIterator.init(transport.allocator, .{});
    var has_ipv6 = false;
    var addrs: std.ArrayList(std.Io.net.IpAddress) = .empty;
    defer addrs.deinit(transport.allocator);

    while (it.next()) |addr| {
        const socket = try transport.socket_handler.registerSocket(
            transport.io,
            transport.allocator,
            &addr,
            transport,
            handleSocketData,
        ) orelse continue;

        if (std.meta.activeTag(addr) == .ip6) has_ipv6 = true;
        try addrs.append(transport.allocator, socket.address);
    }
    try transport.addStunAndTurnServers(has_ipv6);

    const now = Io.Timestamp.now(transport.io, .awake).toMilliseconds();
    try transport.ice_agent.addLocalAddrs(addrs.items, now);
    try transport.group.concurrent(transport.io, TimerManager.run, .{ &transport.timer_manager, transport.io });
    try transport.drainIceEvents();
}

pub fn createPacket(transport: *DtlsTransport) ![]u8 {
    transport.mutex.lockUncancelable(transport.io);
    defer transport.mutex.unlock(transport.io);
    return try transport.memory_pool.create(transport.allocator);
}

pub fn destroyPacket(transport: *DtlsTransport, buffer: []const u8) void {
    transport.mutex.lockUncancelable(transport.io);
    defer transport.mutex.unlock(transport.io);
    transport.memory_pool.destroy(@ptrCast(@alignCast(@constCast(buffer))));
}

pub fn getConnectionState(transport: *const DtlsTransport) struct { ice.ConnectionState, dtls.ConnectionState } {
    return .{ transport.ice_agent.connection_state, transport.session.connection_state };
}

pub fn sendRtp(transport: *DtlsTransport, buffer: []u8, rtp_payload: usize) SendError!void {
    if (transport.session.connection_state != .connected) return;
    const encrypted = try transport.out_srtp_session.?.encryptRtp(buffer[0..rtp_payload], buffer);
    try transport.socket.send(transport.io, &transport.dest, encrypted);
}

pub fn sendRtcp(transport: *DtlsTransport, buffer: []u8, rtcp_payload: usize) SendError!void {
    if (transport.session.connection_state != .connected) return;
    const encrypted = try transport.out_srtp_session.?.encryptRtcp(buffer[0..rtcp_payload], buffer);
    try transport.socket.send(transport.io, &transport.dest, encrypted);
}

pub fn sendData(transport: *DtlsTransport, data: []const u8) !void {
    var buffer: [max_message_size]u8 = undefined;
    const size = try transport.session.writeData(data, &buffer);
    try transport.socket.send(transport.io, &transport.dest, buffer[0..size]);
}

pub fn close(transport: *DtlsTransport) void {
    transport.session.close();
    transport.ice_agent.close();
}

pub fn getRole(transport: *const DtlsTransport) dtls.Role {
    return transport.session.getRole();
}

fn addStunAndTurnServers(transport: *DtlsTransport, has_ipv6: bool) Io.Cancelable!void {
    for (transport.ice_servers) |ice_server| {
        transport.resolveIceServer(ice_server, has_ipv6) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => Logger.warn("Failed to resolve ICE server {s}: {}", .{ ice_server.url, err }),
        };
    }
}

fn resolveIceServer(transport: *DtlsTransport, ice_server: ice.IceServer, has_ipv6: bool) !void {
    const server = try ice.ParsedServerUrl.parse(ice_server.url);
    if (server.scheme != .stun and server.scheme != .turn) return;
    if (server.transport == .tcp) return;

    var resolver = try DnsResolver.init(server.host);
    try resolver.resolve(transport.io, server.port);
    while (try resolver.next(transport.io)) |addr| {
        if (!has_ipv6 and std.meta.activeTag(addr) == .ip6) continue;

        const local_addr = switch (std.meta.activeTag(addr)) {
            .ip4 => Io.net.IpAddress{ .ip4 = .unspecified(0) },
            .ip6 => Io.net.IpAddress{ .ip6 = .unspecified(0) },
        };

        const socket = try transport.socket_handler.registerSocket(
            transport.io,
            transport.allocator,
            &local_addr,
            transport,
            handleSocketData,
        ) orelse continue;
        errdefer transport.socket_handler.unregisterSocket(transport.io, socket);

        try transport.ice_agent.addStunServer(socket.address, addr);
        if (server.scheme == .turn) {
            const turn_socket = try transport.socket_handler.registerSocket(
                transport.io,
                transport.allocator,
                &local_addr,
                transport,
                handleSocketData,
            ) orelse continue;
            errdefer transport.socket_handler.unregisterSocket(transport.io, turn_socket);

            try transport.ice_agent.addTurnServer(
                turn_socket.address,
                addr,
                ice_server.username,
                ice_server.credential,
            );
        }
    }
}

fn handleSocketData(userdata: ?*anyopaque, socket: *Io.net.Socket, inc: Io.net.IncomingMessage) !SocketHandler.ReturnAction {
    const transport: *DtlsTransport = @ptrCast(@alignCast(userdata.?));

    var resp: [1024]u8 = undefined;

    try transport.mutex.lock(transport.io);
    defer transport.mutex.unlock(transport.io);

    const now = Io.Timestamp.now(transport.io, .awake).toMilliseconds();
    const read_result = transport.ice_agent.handleRead(.{
        .data = inc.data,
        .from = &inc.from,
        .to = &socket.address,
    }, now, &resp) catch return .none;

    switch (read_result) {
        .app_data => |data| transport.handleIceData(data) catch |err| {
            Logger.warn("Error while handling ice data: {}", .{err});
        },
        .consumed => transport.drainIceEvents() catch |e| Logger.err("Error while draining events: {}", .{e}),
    }

    return .none;
}

fn handleIceTimeout(userdata: ?*anyopaque, _: TimerManager.Id) void {
    const transport: *DtlsTransport = @ptrCast(@alignCast(userdata.?));
    transport.mutex.lockUncancelable(transport.io);
    defer transport.mutex.unlock(transport.io);
    const now = Io.Timestamp.now(transport.io, .awake).toMilliseconds();
    transport.current_deadline = std.math.maxInt(i64);
    transport.ice_agent.handleTimeout(now) catch |e| Logger.err("Error while handling timeout: {}", .{e});
    transport.drainIceEvents() catch |e| Logger.err("Error while draining events: {}", .{e});
}

fn handleDtlsTimeout(userdata: ?*anyopaque, _: TimerManager.Id) void {
    const transport: *DtlsTransport = @ptrCast(@alignCast(userdata.?));
    transport.mutex.lockUncancelable(transport.io);
    defer transport.mutex.unlock(transport.io);
    const now = Io.Timestamp.now(transport.io, .awake).toMilliseconds();
    transport.session.handleTimeout(now);
    transport.drainDtlsEvents() catch |e| Logger.err("Error while draining dtls events: {}", .{e});
}

fn drainIceEvents(transport: *DtlsTransport) !void {
    const ice_agent = &transport.ice_agent;
    while (ice_agent.pollEvent()) |event| switch (event) {
        .connection_state => |state| {
            switch (state) {
                .connected => {
                    const now = Io.Timestamp.now(transport.io, .awake).toMilliseconds();
                    transport.session.handleTimeout(now);
                    try transport.drainDtlsEvents();
                },
                .completed => transport.socket_handler.unregisterAllExcept(transport.io, transport.allocator, transport.socket),
                else => {},
            }
            transport.on_event(transport, .{ .ice_connection_state = state });
        },
        .candidate => |range| for (range.@"0"..range.@"1" + 1) |idx| {
            transport.on_event(transport, .{ .ice_candidate = transport.ice_agent.candidates[idx] });
        },
        .gathering_state => |state| {
            transport.on_event(transport, .{ .ice_candidate = null });
            transport.on_event(transport, .{ .ice_gathering_state = state });
        },
        .nominated => |pair| {
            const local_addr = ice_agent.candidates[pair.local].base;
            transport.dest = ice_agent.remote_candidates[pair.remote].address;
            Logger.debug("Nominated pair: {f} -> {f}", .{ local_addr, transport.dest });
            transport.socket = transport.socket_handler.findSocket(&local_addr).?;
        },
    };

    while (ice_agent.pollTransmit()) |msg| {
        const socket = transport.socket_handler.findSocket(msg.from) orelse continue;
        socket.send(transport.io, msg.to, msg.data) catch |err| {
            Logger.debug("Failed to send data to {f}: {}", .{ msg.to, err });
        };
    }

    const deadline = ice_agent.pollTimeout() orelse return;
    if (deadline >= transport.current_deadline) return;
    transport.current_deadline = deadline;
    _ = try transport.timer_manager.schedule(
        transport.allocator,
        transport.io,
        deadline,
        transport,
        handleIceTimeout,
    );
}

fn drainDtlsEvents(transport: *DtlsTransport) !void {
    while (transport.session.pollTransmit()) |data| {
        switch (transport.ice_agent.connection_state) {
            .connected, .completed, .disconnected => try transport.socket.send(transport.io, &transport.dest, data),
            else => {},
        }
    }

    while (transport.session.pollEvent()) |event| switch (event) {
        .connection_state => |state| transport.on_event(transport, .{ .dtls_connection_state = state }),
        .srtp_keying_material => |keying| {
            const profile = switch (keying.profile) {
                1 => srtp.Profile.AesCm128HmacSha1_80,
                2 => srtp.Profile.AesCm128HmacSha1_32,
                else => unreachable,
            };

            transport.in_srtp_session = try srtp.Session.init(transport.io, transport.allocator, &keying.remote_keying_material, profile);
            errdefer {
                transport.in_srtp_session.?.deinit();
                transport.in_srtp_session = null;
            }

            transport.out_srtp_session = try srtp.Session.init(transport.io, transport.allocator, &keying.local_keying_material, profile);
        },
    };

    const deadline = transport.session.pollTimeout() orelse return;
    _ = try transport.timer_manager.schedule(
        transport.allocator,
        transport.io,
        deadline,
        transport,
        handleDtlsTimeout,
    );
}

fn handleIceData(transport: *DtlsTransport, data: []const u8) !void {
    switch (getPacketType(data)) {
        .dtls => {
            const buffer = try transport.memory_pool.create(transport.allocator);
            defer transport.memory_pool.destroy(buffer);
            const now = Io.Timestamp.now(transport.io, .awake).toMilliseconds();
            switch (try transport.session.handleRead(data, now, buffer)) {
                .app_data => |app_data| transport.on_data(transport, .{ .app_data = app_data }),
                .consumed => try transport.drainDtlsEvents(),
            }
        },
        .rtp => if (transport.in_srtp_session) |*srtp_session| {
            const buffer = @constCast(data.ptr[0..max_message_size]);
            const rtp_packet = try srtp_session.decryptRtp(data, buffer);
            transport.on_data(transport, .{ .rtp = rtp_packet });
        },
        .rtcp => if (transport.in_srtp_session) |*srtp_session| {
            const buffer = @constCast(data.ptr[0..max_message_size]);
            const rtcp_packet = try srtp_session.decryptRtcp(data, buffer);
            transport.on_data(transport, .{ .rtcp = rtcp_packet });
        },
        .unknown => Logger.debug("Received unknown packet", .{}),
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
