const std = @import("std");
const ice = @import("ice");
const rtp = @import("rtp");
const rtcp = @import("rtcp");

const webrtc = @import("webrtc.zig");
const dtls = @import("dtls/dtls.zig");
const utils = @import("utils.zig");
const constants = @import("constants.zig");

const SDPAttribute = @import("sdp").Attribute.ParsedAttribute;
const DtlsTransport = @import("dtls_transport.zig");
const SctpTransport = @import("sctp_transport.zig");
const SDPSession = @import("sdp_session.zig");
const Demuxer = @import("pc/demuxer2.zig");
const RtpTransceiver = @import("rtp_transceiver.zig");
const RtpSender = @import("rtp_sender.zig");
const Mid = @import("mid.zig");
const NackConfig = @import("pc/nack_config.zig");
const NackGenerator = @import("nack/generator.zig");
const DataChannel = @import("data_channel.zig");

const Io = std.Io;
const PeerConnection = @This();
const Logger = std.log.scoped(.pc);

const packet_size = constants.max_packet_size;

pub const RtpTransceiverID = u32;
pub const RtpSenderID = u32;
pub const RtpReceiverID = u32;

pub const Error = error{
    InvalidState,
    /// Returned when an ssrc cannot be
    /// generated for a sender
    SsrcUnavailable,
    /// Too many transceivers have been added to the PeerConnection and the mid counter has overflowed.
    MidOverflow,
    /// The applied local description does not match the last generated offer/answer.
    TamperedOffer,
    /// An answer has a different number of media sections than the local offer.
    InvalidAnswer,
    /// No local description has been set.
    NoLocalDescription,
    /// A media section references a transceiver that does not exist.
    UnknownTransceiver,
    /// The requested operation is not implemented.
    NotImplemented,
} || std.mem.Allocator.Error;

pub const GatheringState = ice.GatheringState;

/// SignalingState represents the signaling state of the PeerConnection.
pub const SignalingState = enum {
    /// In the stable state there is no offer/answer exchange in progress.
    /// This is also the initial state, in which case the local and remote descriptions are empty.
    stable,
    /// A local description, of type "offer", has been successfully applied.
    have_local_offer,
    /// A remote description, of type "offer", has been successfully applied.
    have_remote_offer,
    /// A remote description of type "offer" has been successfully applied and a local description of
    /// type "pranswer" has been successfully applied.
    have_local_pranswer,
    /// A local description of type "offer" has been successfully applied and a remote description of
    /// type "pranswer" has been successfully applied.
    have_remote_pranswer,
    /// The PeerConnection has been closed.
    closed,
};

/// ConnectionState represents the state of the PeerConnection.
pub const ConnectionState = enum {
    /// The connection has been closed.
    closed,
    /// The PeerConnection transition to this state if either the ice connection is in failed
    /// state or the dtls connection is in failed state.
    failed,
    /// The ice connection of is the disconnected state.
    disconnected,
    /// The initial state of the PeerConnection.
    new,
    /// The ice connection is connected and the dtls connection either is connected or closed.
    connected,
    /// If none of the other states apply, the PeerConnection is in the connecting state.
    connecting,
};

pub const RTCConfiguration = struct {
    /// List of ICE servers (stun/turn) used for candidates gathering.
    ice_servers: []const ice.IceServer = &.{},
};

pub const Config = struct {
    /// This is W3C's RTCConfiguration, which defines a set of parameters to configure the PeerConnection.
    rtc_configuration: RTCConfiguration = .{},
    /// The media engine used to advertise and negotiate codecs. Owned by the caller.
    media_engine: *webrtc.MediaEngine,
    random: std.Random,
    /// NACK configuration. This is used to configure the NACK generator/responder for the PeerConnection.
    nack_config: NackConfig = .{},
};

pub const TrackEventInit = struct {
    receiver_id: RtpReceiverID,
    track: webrtc.MediaStreamTrack,
};

pub const Event = union(enum) {
    negotiation_needed,
    signaling_state: SignalingState,
    candidate: ?ice.Candidate,
    connection_state: ConnectionState,
    gathering_state: GatheringState,
    track: TrackEventInit,
    channel: DataChannel.Event,
};

io: std.Io,
allocator: std.mem.Allocator,
signaling_state: SignalingState,
connection_state: ConnectionState,
negotiation_needed: bool,

local_description: ?ParsedSessionDescription = null,
remote_description: ?ParsedSessionDescription = null,
pending_local_description: ?ParsedSessionDescription = null,
pending_remote_description: ?ParsedSessionDescription = null,
last_offer: ParsedSessionDescription = .empty(.offer),
last_answer: ParsedSessionDescription = .empty(.answer),

media_engine: *webrtc.MediaEngine,
random: std.Random,

streams: std.ArrayList(webrtc.MediaStream) = .empty,
transceivers: std.ArrayList(RtpTransceiver) = .empty,
events: std.Deque(Event),
dtls_transport: DtlsTransport,
sctp_transport: SctpTransport,
demuxer: Demuxer,

/// Used as a counter for generating mid values for transceivers.
mid: u16 = 0,
nominated_pair: ?struct { *const Io.net.IpAddress, *const Io.net.IpAddress } = null,

// RTP/RTCP interceptors
nack_config: NackConfig,
nack_generator: ?NackGenerator = null,

int_buffers: *[2 * packet_size]u8,
sender_report_deadline: i64 = std.math.maxInt(i64),
sender_report_it: ?SenderReportIterator = null,

const ParsedSessionDescription = struct {
    desc_type: webrtc.SessionDescriptionType,
    sdp: []const u8,
    session: SDPSession,

    fn empty(desc_type: webrtc.SessionDescriptionType) ParsedSessionDescription {
        return .{
            .desc_type = desc_type,
            .sdp = &.{},
            .session = .empty,
        };
    }

    fn init(t: webrtc.SessionDescriptionType, sdp: []const u8, session: SDPSession) ParsedSessionDescription {
        return .{
            .desc_type = t,
            .sdp = sdp,
            .session = session,
        };
    }

    fn deinit(sess_desc: *ParsedSessionDescription, allocator: std.mem.Allocator) void {
        allocator.free(sess_desc.sdp);
        sess_desc.session.deinit(allocator);
        sess_desc.* = .empty(sess_desc.desc_type);
    }

    fn toSessionDescription(sess_desc: *const ParsedSessionDescription) webrtc.SessionDescription {
        return .{
            .type = sess_desc.desc_type,
            .sdp = sess_desc.sdp,
        };
    }

    fn getIceRole(sess_desc: *const ParsedSessionDescription) ice.Role {
        if (sess_desc.desc_type == .offer or sess_desc.session.ice_lite) return .controlling;
        return .controlled;
    }
};

const SenderReportIterator = struct {
    index: usize = 0,
    timestamp: i64,

    fn next(it: *SenderReportIterator, pc: *PeerConnection, buffer: []u8) ?[]const u8 {
        const transceivers = pc.getTransceivers();
        while (it.index < transceivers.len) {
            const tr = &transceivers[it.index];
            it.index += 1;
            if (tr.isStopped() or tr.direction == .inactive) continue;
            const data = tr.getRtcpReport(it.timestamp, buffer);
            if (data.len != 0) return data;
        }
        return null;
    }
};

pub fn init(io: Io, allocator: std.mem.Allocator, config: Config) !PeerConnection {
    const buffers = try allocator.create([2 * packet_size]u8);
    buffers.* = @splat(0);
    errdefer allocator.destroy(buffers);

    var dtls_transport: DtlsTransport = try .init(io, allocator, .{ .random = config.random });
    errdefer dtls_transport.deinit();

    return .{
        .io = io,
        .allocator = allocator,
        .random = config.random,
        .signaling_state = .stable,
        .connection_state = .new,
        .negotiation_needed = false,
        .dtls_transport = dtls_transport,
        .demuxer = .init(allocator),
        .nack_config = config.nack_config,
        .media_engine = config.media_engine,
        .sctp_transport = SctpTransport.init(allocator, .{
            .local_port = constants.default_sctp_port,
            .remote_port = 0,
            .random = config.random,
        }),
        .int_buffers = buffers,
        .sender_report_deadline = std.math.maxInt(i64),
        .events = .empty,
    };
}

pub fn deinit(pc: *PeerConnection) void {
    for (pc.transceivers.items) |*tr| tr.deinit(pc.allocator);
    pc.transceivers.deinit(pc.allocator);

    for (pc.streams.items) |*stream| stream.deinit(pc.allocator);
    pc.streams.deinit(pc.allocator);

    pc.deinitDescriptions(&.{
        &pc.local_description,
        &pc.remote_description,
        &pc.pending_local_description,
        &pc.pending_remote_description,
    });

    pc.last_offer.deinit(pc.allocator);
    pc.last_answer.deinit(pc.allocator);

    if (pc.nack_generator) |*ng| ng.deinit();
    pc.sctp_transport.deinit();
    pc.dtls_transport.deinit();
    pc.demuxer.deinit();
    pc.allocator.destroy(pc.int_buffers);
}

/// Adds a new track to the PeerConnection and optionally associates it with a stream.
pub fn addTrack(pc: *PeerConnection, track: webrtc.MediaStreamTrack, stream_id: ?[]const u8) Error!RtpSenderID {
    try pc.checkNotClosed();

    const transceived_id: ?u32 = blk: {
        for (pc.transceivers.items, 0..) |*tr, idx| if (tr.canAssociateTrack(track.kind)) {
            // We relaxed the canAssociateTrack check to allow reusing a transceiver even if the sender
            // already used for sending data. For that we need to reset the rtp sender.
            tr.sender.reset(pc.allocator);
            tr.setSenderTrack(track);
            try pc.generateSsrc(&tr.sender);

            if (stream_id) |sid| {
                const stream = try getOrAddStream(pc, sid);
                tr.sender.setStream(stream);
            }

            break :blk @intCast(idx);
        };

        break :blk null;
    };

    const tr_id = transceived_id orelse try pc.initTransceiverFromTrack(track, stream_id, true);
    pc.checkNegotiationNeeded();
    return tr_id;
}

/// Removes a track from the PeerConnection.
///
/// Removing a track will update the transceiver's direction and stop sending media.
pub fn removeTrack(pc: *PeerConnection, sender_id: RtpSenderID) error{InvalidState}!void {
    try pc.checkNotClosed();
    const tr = &pc.transceivers.items[sender_id];
    tr.removeTrack();
    pc.checkNegotiationNeeded();
}

pub fn getTransceivers(pc: *const PeerConnection) []RtpTransceiver {
    return pc.transceivers.items;
}

/// Creates a new transceiver to the PeerConnection from an existing track.
pub fn addTransceiverFromTrack(pc: *PeerConnection, track: webrtc.MediaStreamTrack, init_config: RtpTransceiver.Init) Error!RtpTransceiverID {
    const tr = try pc.initTransceiverFromTrack(track, init_config.stream_id, false);
    pc.transceivers.items[tr].direction = init_config.direction;
    pc.checkNegotiationNeeded();
    return tr;
}

/// Creates a new transceiver to the PeerConnection from a specified kind of media (audio or video).
///
/// The transceive will initialize a sender without a track. Pair this with `addTrack` to add a track to the sender later.
pub fn addTransceiverFromKind(pc: *PeerConnection, kind: webrtc.TrackKind, init_config: RtpTransceiver.Init) Error!RtpTransceiverID {
    try pc.transceivers.ensureUnusedCapacity(pc.allocator, 1);

    const tr = try pc.allocator.create(RtpTransceiver);
    errdefer pc.allocator.destroy(tr);

    tr.* = .{
        .kind = kind,
        .direction = init_config.direction,
        .sender = .init(null),
        .receiver = webrtc.RtpReceiver.init(.init(pc.io, kind)),
        .pc = pc,
    };

    if (init_config.stream_id) |stream_id| {
        const stream = try getOrAddStream(pc, stream_id);
        tr.sender.setStream(stream);
    }
    try pc.generateSsrc(&tr.sender);

    pc.transceivers.appendAssumeCapacity(tr);
    pc.checkNegotiationNeeded();
    return @intCast(pc.transceivers.items.len - 1);
}

/// Stops the transceiver.
///
/// Prefer calling this instead of `RtpTransceiver.stop()` directly, as this will also check if negotiation is needed.
pub fn stopTransceiver(pc: *PeerConnection, transceiver: *RtpTransceiver) Error!void {
    try pc.checkNotClosed();
    transceiver.stop();
    pc.checkNegotiationNeeded();
}

/// Creates a new offer.
///
/// Pointers are invalidated in the next call to `createOffer`.
pub fn createOffer(pc: *PeerConnection) !webrtc.SessionDescription {
    try pc.checkNotClosed();

    const first_offer = pc.pending_local_description == null and pc.local_description == null;
    return if (first_offer) pc.createFirstOffer() else pc.createSubsequentOffer();
}

/// Creates an answer to a remote offer.
///
/// See [MDN RTCPeerConnection: createAnswer](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/createAnswer)
pub fn createAnswer(pc: *PeerConnection) !webrtc.SessionDescription {
    try pc.checkNotClosed();
    switch (pc.signaling_state) {
        .have_remote_offer, .have_local_pranswer => {},
        else => return error.InvalidState,
    }

    const offer = pc.pending_remote_description.?;
    var w = Io.Writer.Allocating.init(pc.allocator);
    defer w.deinit();

    var sdp_session: SDPSession = .empty;
    errdefer sdp_session.deinit(pc.allocator);

    sdp_session.medias = try .initCapacity(pc.allocator, offer.session.getMedias().len);
    pc.dtls_transport.session.getFingerprint(&sdp_session.fingerprint);

    for (offer.session.getMedias()) |*media| {
        const new_media = sdp_session.medias.addOneAssumeCapacity();
        new_media.* = .empty;
        if (media.isDataChannel()) {
            new_media.* = try media.clone(pc.allocator);
            new_media.port = constants.sdp_default_port;
            new_media.setIceCredentials(pc.dtls_transport.ice_agent.getLocalCredentials());
            new_media.setup = if (media.setup == .active) .passive else .active;
            new_media.sctp_port = pc.sctp_transport.local_port;
            continue;
        }

        new_media.* = if (media.isRejected()) blk: {
            var cloned = try media.clone(pc.allocator);
            cloned.port = 0;
            cloned.bundle_only = false;
            break :blk cloned;
        } else blk: {
            const tr = pc.findTransceiverByMid(media.mid) orelse return error.UnknownTransceiver;
            break :blk try pc.toSdpMediaAnswer(tr, media);
        };
    }

    try sdp_session.write(&w.writer);

    pc.last_answer.deinit(pc.allocator);
    pc.last_answer = .init(.answer, try w.toOwnedSlice(), sdp_session);
    return pc.last_answer.toSessionDescription();
}

/// Get local description.
///
/// This function allocates the sdp buffer inside the `webrtc.SessionDescription`. The caller owns
/// the buffer.
pub fn getLocalDescription(pc: *PeerConnection) !?webrtc.SessionDescription {
    const sess_desc = pc.pending_local_description orelse pc.local_description;
    if (sess_desc) |desc| {
        var w = Io.Writer.Allocating.init(pc.allocator);
        defer w.deinit();

        try pc.writeLocalDescription(&w.writer);

        return .{ .type = desc.desc_type, .sdp = try w.toOwnedSlice() };
    }

    return null;
}

/// Get remote description.
///
/// The buffer is owned by this object and must not be freed.
pub fn getRemoteDescription(pc: *PeerConnection) Error!?webrtc.SessionDescription {
    const sess_desc = pc.pending_remote_description orelse pc.remote_description;
    return if (sess_desc) |*desc| desc.toSessionDescription() else null;
}

/// Apply a local description generated by `createOffer` or `createAnswer`.
///
/// For more details [MDN RTCPeerConnection: setLocalDescription](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/setLocalDescription)
pub fn setLocalDescription(pc: *PeerConnection, session_desc: webrtc.SessionDescription) !void {
    try pc.checkNotClosed();

    switch (session_desc.type) {
        .offer => switch (pc.signaling_state) {
            .stable, .have_local_offer => try pc.applyLocalOffer(&session_desc),
            else => return error.InvalidState,
        },
        .answer => switch (pc.signaling_state) {
            .have_remote_offer => try pc.applyLocalAnswer(&session_desc),
            else => return error.InvalidState,
        },
        else => return error.NotImplemented,
    }
}

/// Apply a remote description received from the remote peer.
pub fn setRemoteDescription(pc: *PeerConnection, session_desc: webrtc.SessionDescription) !void {
    try pc.checkNotClosed();

    switch (session_desc.type) {
        .offer => switch (pc.signaling_state) {
            .have_remote_offer, .stable => try pc.applyRemoteDescription(&session_desc),
            else => return error.InvalidState,
        },
        .answer => switch (pc.signaling_state) {
            .have_local_offer => try pc.applyRemoteDescription(&session_desc),
            else => return error.InvalidState,
        },
        else => return error.NotImplemented,
    }
}

/// Write the local description to a writer.
///
/// This will include the ICE candidates if they have been gathered.
pub fn writeLocalDescription(pc: *PeerConnection, w: *Io.Writer) !void {
    try pc.checkNotClosed();
    const sess_desc = pc.pending_local_description orelse pc.local_description;
    return if (sess_desc) |*desc| try pc.writeDescriptionWithCandidates(desc, w) else error.NoLocalDescription;
}

/// Create a new data channel.
pub fn createDataChannel(pc: *PeerConnection, label: []const u8, params: DataChannel.Parameters) !DataChannel.ChannelId {
    try pc.checkNotClosed();
    if (label.len > constants.max_data_channel_label_length) return error.LabelTooLong;
    if (params.protocol.len > constants.max_data_channel_label_length) return error.ProtocolTooLong;
    if (params.max_packet_lifetime != 0 and params.max_retransmits != 0) return error.InvalidParameters;

    return try pc.sctp_transport.addDataChannel(label, params);
}

pub fn sendDataChannelMessage(pc: *PeerConnection, channel_id: DataChannel.ChannelId, message: []const u8) !void {
    try pc.checkNotClosed();
    try pc.sctp_transport.sendDataChannelMessage(channel_id, message, false);
}

pub fn close(pc: *PeerConnection) void {
    pc.dtls_transport.close();
    pc.sctp_transport.close();
}

pub const ReadResult = union(enum) {
    rtp: struct { RtpReceiverID, rtp.Packet },
    rtcp: RtcpIterator,
    none,
};

pub const RtcpIterator = struct {
    it: rtcp.CompoundPacketIterator,
    pc: *PeerConnection,

    pub fn init(pc: *PeerConnection, data: []const u8) RtcpIterator {
        return .{ .it = rtcp.CompoundPacketIterator.init(data), .pc = pc };
    }

    pub fn next(self: *RtcpIterator) !?struct { RtpTransceiverID, rtcp.Packet } {
        while (try self.it.next()) |packet| switch (packet.payload) {
            .nack => |nack| if (self.pc.findSenderBySsrc(nack.media_ssrc)) |sender_id| {
                try self.pc.transceivers.items[sender_id].sender.handleNack(nack);
                return .{ sender_id, packet };
            },
            else => |payload_type| std.log.info("Rtcp: {s}", .{@tagName(payload_type)}),
        };

        return null;
    }
};

pub fn handleRead(pc: *PeerConnection, message: webrtc.TransportMessage, now: i64) !ReadResult {
    const data_event = (try pc.dtls_transport.handleRead(
        message,
        now,
        pc.int_buffers[0..packet_size],
    )) orelse {
        @branchHint(.unlikely);
        return .none;
    };

    switch (data_event) {
        .rtp => |data| return try pc.handleRtpData(data),
        .rtcp => |data| return .{ .rtcp = .init(pc, data) },
        .app_data => |data| try pc.sctp_transport.handleRead(data, now),
    }

    return .none;
}

pub fn handleTimeout(pc: *PeerConnection, now: i64, wall_clock_us: i64) !void {
    try pc.dtls_transport.handleTimeout(now);
    try pc.sctp_transport.handleTimeout(now);
    if (now >= pc.sender_report_deadline) {
        pc.sender_report_deadline = now + pc.random.intRangeAtMost(u16, 500, 1500);
        if (pc.connection_state == .connected) pc.sender_report_it = .{ .timestamp = wall_clock_us };
    }
    if (pc.nack_generator) |*ng| ng.handleTimeout(now);
}

pub fn pollEvent(pc: *PeerConnection) ?Event {
    while (true) {
        const dtls_event = pc.dtls_transport.pollEvent() orelse {
            const sctp_event = pc.sctp_transport.pollEvent() orelse break;
            switch (sctp_event) {
                .connection_state => |state| Logger.info("SCTP connection state changed: {}", .{state}),
                .data_channel => |dc_event| return .{ .channel = dc_event },
            }
            continue;
        };

        switch (dtls_event) {
            .ice_candidate => |id| return .{ .candidate = pc.dtls_transport.ice_agent.candidates[id] },
            .end_of_candidates => return .{ .candidate = null },
            .ice_connection_state, .dtls_connection_state => {
                const ice_state, const dtls_state = pc.dtls_transport.getConnectionState();
                const new_state = nextPeerConnectionState(ice_state, dtls_state);
                if (new_state != pc.connection_state) {
                    pc.connection_state = new_state;
                    if (pc.connection_state == .connected) {
                        pc.maybeConnectSctpTransport() catch |err| {
                            Logger.err("Failed to connect SCTP transport: {}", .{err});
                        };
                    }

                    if (pc.connection_state == .closed) pc.setSignalingState(.closed);
                    return .{ .connection_state = new_state };
                }
            },
            .ice_gathering_state => |state| return .{ .gathering_state = state },
            .nominated => |pair| {
                const local_candidate = &pc.dtls_transport.ice_agent.candidates[pair.local];
                const dest = &pc.dtls_transport.ice_agent.remote_candidates[pair.remote].address;
                pc.nominated_pair = .{ &local_candidate.base, dest };
            },
        }
    }

    return pc.events.popFront();
}

pub fn pollTransmit(pc: *PeerConnection, buffer: []u8, now: i64) !?webrtc.TransportMessage {
    const buffer2 = pc.int_buffers[packet_size .. 2 * packet_size];

    const data = blk: {
        switch (pc.dtls_transport.pollTransmit(buffer)) {
            .none => {},
            .ice => |msg| return .{
                .data = msg.data,
                .from = msg.from,
                .to = msg.to,
            },
            .bin => |data| if (pc.nominated_pair != null) break :blk data,
        }

        if (pc.sctp_transport.pollTransmit(buffer2, now)) |sctp_data| {
            break :blk pc.dtls_transport.handleWrite(sctp_data, buffer);
        }

        if (pc.sender_report_it) |*it| {
            if (it.next(pc, buffer)) |data| {
                break :blk try pc.dtls_transport.handleMediaWrite(buffer, data.len, false);
            }
            pc.sender_report_it = null;
        }

        if (pc.nack_generator) |*ng| if (try ng.pollTransmit(buffer[0..1200])) |data| {
            break :blk try pc.dtls_transport.handleMediaWrite(buffer, data.len, false);
        };

        return null;
    };

    return .{
        .data = data,
        .from = pc.nominated_pair.?.@"0",
        .to = pc.nominated_pair.?.@"1",
    };
}

pub fn pollTimeout(pc: *PeerConnection) ?i64 {
    const dtls_timeout = pc.dtls_transport.pollTimeout() orelse std.math.maxInt(i64);
    const sctp_timeout = pc.sctp_transport.pollTimeout() orelse std.math.maxInt(i64);
    const nack_deadline = if (pc.nack_generator) |*ng| ng.pollTimeout() else std.math.maxInt(i64);
    const deadline = @min(@min(pc.sender_report_deadline, nack_deadline), @min(dtls_timeout, sctp_timeout));
    return if (deadline == std.math.maxInt(i64)) null else deadline;
}

pub fn addLocalCandidates(pc: *PeerConnection, addrs: []const Io.net.IpAddress, now: i64) !void {
    try pc.dtls_transport.addIceLocalAddrs(addrs, now);
}

fn deinitDescriptions(pc: *PeerConnection, descriptions: []const *?ParsedSessionDescription) void {
    for (descriptions) |desc| if (desc.*) |*d| d.deinit(pc.allocator);
}

fn checkNotClosed(pc: *const PeerConnection) !void {
    if (pc.connection_state == .closed) return error.InvalidState;
}

fn initTransceiverFromTrack(
    pc: *PeerConnection,
    track: webrtc.MediaStreamTrack,
    stream_id: ?[]const u8,
    added_by_add_track: bool,
) !RtpTransceiverID {
    try pc.transceivers.ensureUnusedCapacity(pc.allocator, 1);

    var tr = RtpTransceiver{
        .kind = track.kind,
        .direction = .sendrecv,
        .sender = .init(track),
        .receiver = webrtc.RtpReceiver.init(track),
        .added_by_add_track = added_by_add_track,
        .pc = pc,
    };

    if (stream_id) |sid| {
        const stream = try getOrAddStream(pc, sid);
        tr.sender.setStream(stream);
    }
    try pc.generateSsrc(&tr.sender);

    pc.transceivers.appendAssumeCapacity(tr);
    return @intCast(pc.transceivers.items.len - 1);
}

fn getOrAddStream(pc: *PeerConnection, stream_id: []const u8) !webrtc.MediaStream {
    for (pc.streams.items) |stream| if (std.mem.eql(u8, stream.id, stream_id)) return stream;
    var stream: webrtc.MediaStream = try .init(pc.allocator, stream_id);
    errdefer stream.deinit(pc.allocator);
    try pc.streams.append(pc.allocator, stream);
    return pc.streams.getLast();
}

fn createFirstOffer(pc: *PeerConnection) !webrtc.SessionDescription {
    var w = std.Io.Writer.Allocating.init(pc.allocator);
    errdefer w.deinit();

    var sdp_session: SDPSession = .empty;
    errdefer sdp_session.deinit(pc.allocator);
    pc.dtls_transport.session.getFingerprint(&sdp_session.fingerprint);

    const transceivers = pc.transceivers.items;
    sdp_session.medias = try .initCapacity(pc.allocator, transceivers.len + 1);
    var medias = &sdp_session.medias;

    var mid = pc.mid;
    for (transceivers) |*tr| {
        if (tr.stopping and tr.mid == null) continue;
        const media = medias.addOneAssumeCapacity();
        media.* = .empty;
        media.* = try pc.toSdpMedia(tr);
        media.mid = try Mid.fromInt(mid);

        tr.sdp_mline_index = @intCast(medias.items.len - 1);
        mid +%= 1;
    }

    if (pc.sctp_transport.hasDataChannels()) {
        try pc.initDataChannelMedia(medias.addOneAssumeCapacity());
    }

    try sdp_session.write(&w.writer);

    pc.last_offer.deinit(pc.allocator);
    pc.last_offer = .init(.offer, try w.toOwnedSlice(), sdp_session);
    return pc.last_offer.toSessionDescription();
}

fn createSubsequentOffer(pc: *PeerConnection) !webrtc.SessionDescription {
    const sess_desc = pc.pending_local_description orelse pc.local_description.?;
    const remote_desc = pc.pending_remote_description orelse pc.remote_description;

    var sdp_session = try sess_desc.session.clone(pc.allocator);
    errdefer sdp_session.deinit(pc.allocator);

    var w = std.Io.Writer.Allocating.init(pc.allocator);
    errdefer w.deinit();

    const app_media: ?*SDPSession.Media = blk: {
        for (sdp_session.getMedias()) |*media| if (media.isDataChannel()) break :blk media;
        break :blk null;
    };

    const transceivers = pc.transceivers.items;
    for (transceivers) |*tr| if (tr.sdp_mline_index == null) {
        if (tr.isStopped()) continue;
        // Check if we can recycle a media
        const media = blk: {
            const remote_medias = if (remote_desc) |*desc| desc.session.getMedias() else &.{};
            for (sdp_session.getMedias(), 0..) |*media, idx| {
                if (media.isDataChannel()) continue;

                const remote_rejected = if (remote_medias.len <= idx) false else remote_medias[idx].port == 0;
                if (media.port == 0 or remote_rejected) {
                    media.deinit(pc.allocator);
                    media.* = .empty;

                    for (transceivers) |*local_tr| if (local_tr.sdp_mline_index) |tr_idx| if (tr_idx == idx) {
                        local_tr.sdp_mline_index = null;
                    };

                    tr.sdp_mline_index = @intCast(idx);
                    break :blk media;
                }
            }

            const media = try sdp_session.medias.addOne(pc.allocator);
            media.* = .empty;
            tr.sdp_mline_index = @intCast(sdp_session.medias.items.len - 1);
            break :blk media;
        };
        media.* = try pc.toSdpMedia(tr);
        media.mid = try Mid.fromInt(pc.mid);
        pc.mid +%= 1;
    };

    for (transceivers) |tr| if (tr.sdp_mline_index) |idx| {
        const media = &sdp_session.getMedias()[idx];
        media.port = if (tr.isStopped()) constants.sdp_rejected_port else constants.sdp_default_port;
        // TODO: other field to update
    };

    if (pc.sctp_transport.hasDataChannels()) {
        if (app_media == null)
            try pc.initDataChannelMedia(try sdp_session.medias.addOne(pc.allocator))
        else
            app_media.?.port = constants.sdp_default_port;
    }

    try sdp_session.write(&w.writer);
    try pc.writeIceCandidates(&w.writer);

    pc.last_offer.deinit(pc.allocator);
    pc.last_offer = .init(.offer, try w.toOwnedSlice(), sdp_session);

    return pc.last_offer.toSessionDescription();
}

fn initDataChannelMedia(pc: *PeerConnection, media: *SDPSession.Media) !void {
    media.* = .empty;
    media.kind = .application;
    media.port = constants.sdp_default_port;
    media.sctp_port = pc.sctp_transport.local_port;
    media.mid = try Mid.fromInt(pc.mid);
    media.setIceCredentials(pc.dtls_transport.ice_agent.getLocalCredentials());
    pc.mid +%= 1;
}

fn checkNegotiationNeeded(pc: *PeerConnection) void {
    if (pc.signaling_state != .stable) return;

    if (pc.isNegotiationNeeded()) {
        if (pc.negotiation_needed) return;
        pc.negotiation_needed = true;
        pc.events.pushBack(pc.allocator, .negotiation_needed) catch @panic("OOM");
    } else {
        pc.negotiation_needed = false;
    }
}

fn isNegotiationNeeded(pc: *const PeerConnection) bool {
    // TODO: Check ice restart
    const local_desc = pc.local_description orelse return false;
    const remote_desc = pc.remote_description orelse return false;
    for (pc.getTransceivers()) |tr| {
        if (tr.stopping and !tr.stopped) return true;
        if (!tr.isStopped()) {
            if (tr.sdp_mline_index == null) return true;
            const local_media = local_desc.session.getMedias()[tr.sdp_mline_index.?];
            const remote_media = remote_desc.session.getMedias()[tr.sdp_mline_index.?];
            // TODO: check msid
            if (local_desc.desc_type == .offer and local_media.direction != tr.direction and remote_media.direction.reverse() != tr.direction) return true;
            if (local_desc.desc_type == .answer and local_media.direction != tr.direction.intersect(remote_media.direction)) return true;
        } else if (tr.sdp_mline_index) |idx| {
            const local_media = local_desc.session.getMedias()[idx];
            const remote_media = remote_desc.session.getMedias()[idx];
            if (local_media.port != 0 and remote_media.port != 0) return true;
        }
    }

    return false;
}

fn nextPeerConnectionState(ice_state: ice.ConnectionState, dtls_state: dtls.ConnectionState) ConnectionState {
    return if (ice_state == .closed)
        .closed
    else if (ice_state == .failed or dtls_state == .failed)
        .failed
    else if (ice_state == .disconnected)
        .disconnected
    else if (ice_state == .new and (dtls_state == .new or dtls_state == .closed))
        .new
    else if ((ice_state == .connected or ice_state == .completed) and (dtls_state == .connected or dtls_state == .closed))
        .connected
    else
        .connecting;
}

fn writeDescriptionWithCandidates(pc: *PeerConnection, sess_desc: *const ParsedSessionDescription, w: *Io.Writer) !void {
    const session = sess_desc.session;
    const maybe_media = blk: {
        for (session.getMedias()) |*media| if (!media.isRejected()) break :blk media;
        break :blk null;
    };

    const ice_agent = &pc.dtls_transport.ice_agent;

    if (maybe_media) |media| {
        media.candidates = ice_agent.candidates[0..ice_agent.candidates_len];
        media.end_of_candidates = ice_agent.gathering_state == .complete;
        defer media.candidates = &.{};

        try sess_desc.session.write(w);
    } else try w.writeAll(sess_desc.sdp);
}

fn setSignalingState(pc: *PeerConnection, state: SignalingState) void {
    if (pc.signaling_state == state) return;
    pc.signaling_state = state;
    pc.events.pushBack(pc.allocator, .{ .signaling_state = state }) catch @panic("OOM");
}

fn applyLocalOffer(pc: *PeerConnection, sess_desc: *const webrtc.SessionDescription) !void {
    if (!std.mem.eql(u8, pc.last_offer.sdp, sess_desc.sdp)) return error.TamperedOffer;

    const offer = pc.last_offer.session;
    for (offer.getMedias(), 0..) |*media, idx| {
        if (media.isDataChannel()) continue;
        const transceiver = pc.findTransceiverByMediaIndex(idx).?;
        transceiver.mid = media.mid;
    }

    if (pc.dtls_transport.ice_agent.gathering_state == .new) {
        pc.dtls_transport.ice_agent.role = pc.last_offer.getIceRole();
    }

    if (pc.pending_local_description) |*desc| desc.deinit(pc.allocator);

    pc.last_answer.deinit(pc.allocator);
    pc.pending_local_description = pc.last_offer;
    pc.last_offer = .empty(.offer);

    pc.mid +%= @intCast(offer.getMedias().len);
    pc.setSignalingState(.have_local_offer);
}

fn applyLocalAnswer(pc: *PeerConnection, sess_desc: *const webrtc.SessionDescription) !void {
    if (!std.mem.eql(u8, pc.last_answer.sdp, sess_desc.sdp)) return error.TamperedOffer;
    const sdp_session = pc.last_answer.session;
    const renegotiation = pc.local_description != null;

    var media_exists: bool = false;
    for (sdp_session.getMedias()) |*media| {
        if (media.port == 0) continue;
        media_exists = true;

        if (media.isDataChannel()) continue;
        const tr = pc.findTransceiverByMid(media.mid).?;
        try tr.sender.setCodecs(
            pc.allocator,
            pc.random,
            media.rtp_codec_parameters,
            pc.nack_config.send_buffer_size,
        );
        tr.receiver.setCodecs(media.rtp_codec_parameters);
        tr.sender.setHeaderExtensions(media.rtp_header_extensions);
        tr.receiver.header_extensions = media.rtp_header_extensions;
        // TODO: track removal
        tr.current_direction = media.direction;
        tr.fired_direction = media.direction;
    }

    // if there's no negotiated media, don't start connectivity checks
    if (media_exists and !renegotiation) {
        pc.dtls_transport.ice_agent.role = pc.last_answer.getIceRole();
    }

    try pc.demuxer.updateMaps(&sdp_session, pc.transceivers.items);
    try pc.startRtpRtcpInterceptors();
    pc.maybeCloseSctpTransport(&sdp_session);

    pc.last_offer.deinit(pc.allocator);
    pc.pending_local_description = pc.last_answer;
    pc.updateSignalingStateToStable();
}

fn applyRemoteDescription(pc: *PeerConnection, session_desc: *const webrtc.SessionDescription) !void {
    const sdp_text = try pc.allocator.dupe(u8, session_desc.sdp);
    errdefer pc.allocator.free(sdp_text);

    var remote_sdp = try SDPSession.parse(pc.allocator, sdp_text);
    errdefer remote_sdp.deinit(pc.allocator);

    if (session_desc.type == .answer) {
        const local_session = pc.pending_local_description.?.session;
        if (remote_sdp.getMedias().len != local_session.getMedias().len) return error.InvalidAnswer;
    }

    var first_media: ?*SDPSession.Media = null;
    var track_events: std.ArrayList(RtpTransceiver.TrackEventInit) = .empty;
    defer track_events.deinit(pc.allocator);
    for (remote_sdp.getMedias(), 0..) |*media, idx| {
        if (media.isDataChannel()) {
            if (media.isRejected()) continue;
            first_media = first_media orelse media;
            pc.sctp_transport.remote_port = media.sctp_port.?;
            continue;
        }

        var transceiver = blk: {
            switch (session_desc.type) {
                .answer => {
                    const tr = pc.findTransceiverByMediaIndex(idx) orelse return error.UnknownTransceiver;
                    break :blk tr;
                },
                .offer => {
                    if (pc.findTransceiverByMid(media.mid)) |tr| break :blk tr;
                    for (pc.transceivers.items) |*tr| if (tr.canAssociateMedia(media)) break :blk tr;

                    try pc.transceivers.append(
                        pc.allocator,
                        RtpTransceiver.initFromSdpMedia(media, pc.random, @intCast(idx)),
                    );
                    break :blk &pc.transceivers.items[pc.transceivers.items.len - 1];
                },
                else => unreachable,
            }
        };

        transceiver.mid = media.mid;
        transceiver.sdp_mline_index = @intCast(idx);

        if (media.isRejected() or transceiver.isStopped()) {
            if (!transceiver.isStopped()) transceiver.stop();
            continue;
        }

        first_media = first_media orelse media;

        const direction = media.direction.reverse();
        const msid: ?webrtc.MediaStream = switch (direction) {
            .recvonly, .sendrecv => if (media.msid) |m| try getOrAddStream(pc, m.id) else null,
            else => null,
        };
        transceiver.current_direction = direction;

        if (session_desc.type == .answer) {
            const local_sdp = &pc.pending_local_description.?.session;
            const local_codecs = local_sdp.getMedias()[idx].rtp_codec_parameters;
            const remote_codecs = media.rtp_codec_parameters;
            const codecs = try utils.intersectCodecs(remote_codecs, local_codecs);

            try transceiver.sender.setCodecs(pc.allocator, pc.random, codecs.@"0", pc.nack_config.send_buffer_size);
            transceiver.receiver.setCodecs(codecs.@"1");

            const local_extensions = local_sdp.getMedias()[idx].rtp_header_extensions;
            const remote_extensions = media.rtp_header_extensions;
            const extensions = utils.intersectHeaderExtensions(local_extensions, remote_extensions);

            transceiver.sender.setHeaderExtensions(extensions);
            transceiver.receiver.header_extensions = extensions;
        }

        if (transceiver.processRemoteTrack(direction, msid)) |track_init_event| {
            try track_events.append(pc.allocator, track_init_event);
        }
    }

    if (first_media) |media| {
        try pc.dtls_transport.applyIceAttributes(media, &remote_sdp.fingerprint);
    }

    switch (session_desc.type) {
        .answer => {
            try pc.demuxer.updateMaps(&remote_sdp, pc.transceivers.items);
            try pc.startRtpRtcpInterceptors();
            pc.maybeCloseSctpTransport(&remote_sdp);

            pc.pending_remote_description = .init(.answer, sdp_text, remote_sdp);
            pc.updateSignalingStateToStable();
        },
        .offer => {
            if (pc.pending_remote_description) |*desc| desc.deinit(pc.allocator);
            pc.pending_remote_description = .init(.offer, sdp_text, remote_sdp);
            pc.setSignalingState(.have_remote_offer);
        },
        else => {},
    }

    try pc.events.ensureUnusedCapacity(pc.allocator, track_events.items.len);
    for (track_events.items) |event| {
        const receiver_id: RtpTransceiverID = blk: {
            for (pc.transceivers.items, 0..) |*tr, idx| if (tr == event.transceiver) break :blk @intCast(idx);
            unreachable;
        };

        pc.events.pushBackAssumeCapacity(.{ .track = .{
            .receiver_id = receiver_id,
            .track = event.track,
        } });
    }
}

fn updateSignalingStateToStable(pc: *PeerConnection) void {
    pc.deinitDescriptions(&.{ &pc.local_description, &pc.remote_description });

    pc.local_description = pc.pending_local_description;
    pc.remote_description = pc.pending_remote_description;

    pc.pending_local_description = null;
    pc.pending_remote_description = null;

    pc.last_answer = .empty(.answer);
    pc.last_offer = .empty(.offer);

    pc.setSignalingState(.stable);

    pc.negotiation_needed = false;
    pc.checkNegotiationNeeded();
}

fn findTransceiverByMediaIndex(pc: *PeerConnection, index: usize) ?*RtpTransceiver {
    for (pc.transceivers.items) |*tr| if (tr.sdp_mline_index) |tr_index| if (tr_index == index) return tr;
    return null;
}

fn findTransceiverByMid(pc: *PeerConnection, mid: Mid.Int) ?*RtpTransceiver {
    for (pc.transceivers.items) |*tr| {
        if (tr.mid) |tr_mid| if (tr_mid == mid) return tr;
    }

    return null;
}

fn handleRtpData(pc: *PeerConnection, data: []const u8) !ReadResult {
    var packet = try rtp.Packet.parse(data);

    const id: u32 = switch (pc.demuxer.getTransceiver(&packet)) {
        .transceiver => |id| id,
        .mid => |mid| blk: {
            for (pc.transceivers.items, 0..) |tr, idx| if (tr.mid) |tr_mid| if (tr_mid == mid) {
                try pc.demuxer.cacheSsrc(packet.header.ssrc, @intCast(idx));
                break :blk @intCast(idx);
            };

            return .none;
        },
        .none => return .none,
    };

    const tr = &pc.transceivers.items[id];
    if (try tr.receiver.handleRtpPacket(&packet)) {
        if (tr.receiver.nack) if (pc.nack_generator) |*nack_generator| try nack_generator.handleRead(&packet);
        return .{ .rtp = .{ id, packet } };
    }

    return .none;
}

fn findSenderBySsrc(pc: *PeerConnection, ssrc: u32) ?RtpSenderID {
    for (pc.transceivers.items, 0..) |tr, idx| if (tr.sender.ssrc == ssrc) return @intCast(idx);
    return null;
}

fn writeIceCandidates(pc: *PeerConnection, w: *Io.Writer) !void {
    const ice_agent = &pc.dtls_transport.ice_agent;

    for (ice_agent.candidates[0..ice_agent.candidates_len]) |*candidate| {
        try w.print("a=candidate:{f}\r\n", .{candidate});
    }

    if (ice_agent.gathering_state == .complete) {
        const attr: SDPAttribute = .end_of_candidates;
        try attr.write(w);
    }
}

fn maybeCloseSctpTransport(pc: *PeerConnection, sdp_session: *const SDPSession) void {
    if (sdp_session.getApplicationMedia()) |media| {
        if (media.isRejected() or media.sctp_port.? == 0) pc.sctp_transport.close();
    }
}

fn maybeConnectSctpTransport(pc: *PeerConnection) !void {
    const local_sess = pc.local_description.?.session;
    const remote_sess = pc.remote_description.?.session;
    if (local_sess.getApplicationMedia()) |local| if (remote_sess.getApplicationMedia()) |remote| {
        if (local.isRejected() or remote.isRejected()) return;
        if (local.sctp_port.? == 0 or remote.sctp_port.? == 0) return;
        try pc.sctp_transport.connect(pc.dtls_transport.getRole() == .server);
    };
}

fn startRtpRtcpInterceptors(pc: *PeerConnection) !void {
    const io = pc.io;

    // Init sender reports
    if (pc.sender_report_deadline == std.math.maxInt(i64)) {
        const now = Io.Timestamp.now(io, .awake).toMilliseconds();
        pc.sender_report_deadline = now + 1000;
    }

    // Nack generators
    var nack = false;
    for (pc.getTransceivers()) |tr| {
        if (tr.canReceive() and tr.receiver.nack) {
            nack = true;
            if (pc.nack_generator == null) {
                pc.nack_generator = .init(pc.allocator, .{
                    .size = pc.nack_config.receive_log_size,
                    .interval = pc.nack_config.interval,
                });
            }
        } else if (pc.nack_generator) |*ng| if (tr.receiver.ssrc) |ssrc| ng.deleteSource(ssrc);
    }

    if (!nack) if (pc.nack_generator) |*nack_generator| {
        nack_generator.deinit();
        pc.nack_generator = null;
    };
}

fn toSdpMedia(pc: *PeerConnection, tr: *RtpTransceiver) std.mem.Allocator.Error!SDPSession.Media {
    var media: SDPSession.Media = .empty;

    media.setKind(tr.kind);
    media.port = if (tr.stopping) constants.sdp_rejected_port else constants.sdp_default_port;
    media.direction = tr.direction;
    media.rtp_codec_parameters = try pc.allocator.dupe(webrtc.RtpCodecParameters, pc.media_engine.getCodecs(tr.kind));
    media.rtp_header_extensions = try pc.allocator.dupe(
        webrtc.RtpHeaderExtensionParameter,
        webrtc.getHeaderExtensionCapabilities(tr.kind),
    );
    media.rtcp_mux = true;
    media.rtcp_rsize = false;
    media.setIceCredentials(pc.dtls_transport.ice_agent.getLocalCredentials());

    try addSenderFields(pc.allocator, &media, tr);
    if (tr.mid) |mid| media.mid = mid;

    return media;
}

fn toSdpMediaAnswer(pc: *const PeerConnection, tr: *const RtpTransceiver, media: *SDPSession.Media) std.mem.Allocator.Error!SDPSession.Media {
    var answer: SDPSession.Media = .empty;
    errdefer answer.deinit(pc.allocator);

    const codecs = try utils.getCodecIntersection(
        pc.allocator,
        pc.media_engine.getCodecs(tr.kind),
        media.rtp_codec_parameters,
    );
    defer if (answer.port == 0) pc.allocator.free(codecs);

    const rejected = codecs.len == 0 or tr.isStopped() or media.isRejected();

    answer.setKind(tr.kind);
    answer.port = if (rejected) constants.sdp_rejected_port else constants.sdp_default_port;
    answer.rtcp_mux = true;
    answer.rtcp_rsize = false;
    answer.mid = tr.mid.?;
    answer.setup = switch (media.setup) {
        .active => .passive,
        else => .active,
    };
    answer.direction = media.direction.reverse().intersect(tr.direction);
    answer.rtp_codec_parameters = if (answer.port == 0)
        try pc.allocator.dupe(webrtc.RtpCodecParameters, media.rtp_codec_parameters)
    else
        codecs;
    answer.rtp_header_extensions = if (!rejected) try pc.allocator.dupe(
        webrtc.RtpHeaderExtensionParameter,
        utils.intersectHeaderExtensions(
            media.rtp_header_extensions,
            webrtc.getHeaderExtensionCapabilities(tr.kind),
        ),
    ) else &.{};

    if (!rejected) {
        answer.setIceCredentials(pc.dtls_transport.ice_agent.getLocalCredentials());
    }

    if (!rejected) try addSenderFields(pc.allocator, media, tr);
    return answer;
}

fn addSenderFields(allocator: std.mem.Allocator, media: *SDPSession.Media, tr: *const RtpTransceiver) !void {
    switch (tr.direction) {
        .sendonly, .sendrecv => {
            const track = &tr.sender.track.?;
            if (track.stream_id) |stream_id| media.msid = .{ .id = stream_id };
            media.track_id = try allocator.dupe(u8, track.getId());
            media.ssrc = tr.sender.ssrc;
            for (media.rtp_codec_parameters) |codec| if (codec.isRtx()) {
                media.rtx_ssrc = tr.sender.rtx_ssrc;
                break;
            };
        },
        else => {},
    }
}

fn generateSsrc(pc: *PeerConnection, sender: *RtpSender) !void {
    sender.ssrc = try pc.demuxer.registerRandomSsrc(pc.random);
    sender.rtx_ssrc = try pc.demuxer.registerRandomSsrc(pc.random);
}

test {
    // _ = @import("tests/peer_connection.zig");
    _ = @import("pc/demuxer2.zig");
    _ = @import("nack/send_buffer.zig");
    _ = @import("nack/receive_log.zig");
    _ = @import("nack/generator.zig");
    _ = @import("data_channel.zig");
}

test "nextPeerConnectionState" {
    try std.testing.expectEqual(.new, nextPeerConnectionState(.new, .new));
    try std.testing.expectEqual(.new, nextPeerConnectionState(.new, .closed));
    try std.testing.expectEqual(.connecting, nextPeerConnectionState(.checking, .connecting));
    try std.testing.expectEqual(.connecting, nextPeerConnectionState(.new, .connecting));
    try std.testing.expectEqual(.connected, nextPeerConnectionState(.completed, .connected));
    try std.testing.expectEqual(.connected, nextPeerConnectionState(.connected, .closed));
    try std.testing.expectEqual(.connected, nextPeerConnectionState(.connected, .connected));
    try std.testing.expectEqual(.disconnected, nextPeerConnectionState(.disconnected, .connected));
    try std.testing.expectEqual(.failed, nextPeerConnectionState(.connected, .failed));
    try std.testing.expectEqual(.failed, nextPeerConnectionState(.failed, .connected));
    try std.testing.expectEqual(.closed, nextPeerConnectionState(.closed, .connected));
}
