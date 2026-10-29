const std = @import("std");
const ice = @import("ice");
const rtp = @import("rtp");
const rtcp = @import("rtcp");
const sctp = @import("sctp");

const webrtc = @import("webrtc.zig");
const dtls = @import("dtls/dtls.zig");
const utils = @import("utils.zig");
const constants = @import("constants.zig");

const SDPAttribute = @import("sdp").Attribute.ParsedAttribute;
const DtlsTransport = @import("dtls_transport.zig");
const SctpTransport = @import("sctp_transport.zig");
const SDPSession = @import("sdp_session.zig");
const Demuxer = @import("pc/demuxer.zig");
const RtpTransceiver = @import("rtp_transceiver.zig");
const InternalRtpTransceiver = @import("pc/internal_rtp_transceiver.zig");
const RtpSender = @import("rtp_sender.zig");
const InternalRtpSender = @import("pc/internal_rtp_sender.zig");
const RtpReceiver = @import("rtp_receiver.zig");
const Mid = @import("mid.zig");
const NackConfig = @import("pc/nack_config.zig");
const NackGenerator = @import("nack/generator.zig");
const DataChannel = @import("data_channel.zig");
const InternalDataChannel = @import("internal_data_channel.zig");

const Io = std.Io;
const PeerConnection = @This();
const Logger = std.log.scoped(.pc);

const packet_size = constants.max_packet_size;

pub const RtpTransceiverID = RtpTransceiver.TransceiverID;
pub const RtpSenderID = RtpSender.SenderID;
pub const RtpReceiverID = RtpReceiver.ReceiverID;

/// Returned by every operation called after the PeerConnection has been closed.
pub const ClosedError = error{
    /// `close` was called or the connection state transitioned to `closed`.
    ConnectionClosed,
};

/// Returned by signaling operations.
pub const SignalingError = ClosedError || error{
    /// The operation is not allowed in the current signaling state, e.g. creating an answer
    /// without a pending remote offer.
    InvalidState,
};

pub const Error = ClosedError || error{
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
    /// Must be a cryptographically secure generator (e.g. `std.Random.DefaultCsprng` seeded from
    /// `Io.randomSecure`); it is used for ICE credentials, DTLS, SCTP and RTP identifiers.
    random: std.Random,
    /// NACK configuration. This is used to configure the NACK generator/responder for the PeerConnection.
    nack_config: NackConfig = .{},
};

pub const TrackEventInit = struct {
    receiver: RtpReceiver,
    track: webrtc.MediaStreamTrack,
};

pub const Event = union(enum) {
    negotiation_needed,
    signaling_state: SignalingState,
    candidate: ?ice.Candidate,
    connection_state: ConnectionState,
    gathering_state: GatheringState,
    track: TrackEventInit,
    data_channel: DataChannel.Event,
};

const Transmit = union(enum) {
    nack: RtpSenderID,
};

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
transceivers: std.ArrayList(InternalRtpTransceiver),
data_channels: std.ArrayList(InternalDataChannel),

events: std.Deque(Event),
transmits: std.Deque(Transmit),

dtls_transport: DtlsTransport,
sctp_transport: SctpTransport,
demuxer: Demuxer,

/// Used as a counter for generating mid values for transceivers.
mid: u16 = 0,

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
        const transceivers = pc.transceivers.items;
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

pub const InitError = NackConfig.Error || DtlsTransport.InitError;

pub fn init(io: Io, allocator: std.mem.Allocator, config: Config) InitError!PeerConnection {
    try config.nack_config.validate();

    const buffers = try allocator.create([2 * packet_size]u8);
    buffers.* = @splat(0);
    errdefer allocator.destroy(buffers);

    var dtls_transport: DtlsTransport = try .init(io, allocator, .{ .random = config.random });
    errdefer dtls_transport.deinit();

    return .{
        .allocator = allocator,
        .random = config.random,
        .signaling_state = .stable,
        .connection_state = .new,
        .negotiation_needed = false,
        .transceivers = .empty,
        .data_channels = .empty,
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
        .transmits = .empty,
    };
}

pub fn deinit(pc: *PeerConnection) void {
    for (pc.transceivers.items) |*tr| tr.deinit(pc.allocator);
    pc.transceivers.deinit(pc.allocator);

    for (pc.data_channels.items) |*data_channel| data_channel.deinit(pc.allocator);
    pc.data_channels.deinit(pc.allocator);

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

    pc.events.deinit(pc.allocator);
    pc.transmits.deinit(pc.allocator);
}

/// Adds a new track to the PeerConnection and optionally associates it with a stream.
pub fn addTrack(pc: *PeerConnection, track: webrtc.MediaStreamTrack, stream_id: ?[]const u8) Error!RtpSender {
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
    try pc.checkNegotiationNeeded();
    return pc.getRtpSender(tr_id);
}

/// Removes a track from the PeerConnection.
///
/// Removing a track will update the transceiver's direction and stop sending media.
pub fn removeTrack(pc: *PeerConnection, sender_id: RtpSenderID) (ClosedError || std.mem.Allocator.Error)!void {
    try pc.checkNotClosed();
    const tr = &pc.transceivers.items[sender_id];
    tr.removeTrack();
    try pc.checkNegotiationNeeded();
}

pub fn getRtpSender(pc: *PeerConnection, id: RtpSenderID) RtpSender {
    std.debug.assert(id < pc.transceivers.items.len);
    return .{ .id = id, .pc = pc };
}

pub fn getRtpReceiver(pc: *PeerConnection, id: RtpReceiverID) RtpReceiver {
    std.debug.assert(id < pc.transceivers.items.len);
    return .{ .id = id, .pc = pc };
}

pub fn getRtpTransceiver(pc: *PeerConnection, id: RtpTransceiverID) RtpTransceiver {
    std.debug.assert(id < pc.transceivers.items.len);
    return .{ .id = id, .pc = pc };
}

/// Creates a new transceiver to the PeerConnection from an existing track.
pub fn addTransceiverFromTrack(pc: *PeerConnection, track: webrtc.MediaStreamTrack, init_config: RtpTransceiver.Init) Error!RtpTransceiver {
    const tr = try pc.initTransceiverFromTrack(track, init_config.stream_id, false);
    pc.transceivers.items[tr].direction = init_config.direction;
    try pc.checkNegotiationNeeded();
    return pc.getRtpTransceiver(tr);
}

/// Creates a new transceiver to the PeerConnection from a specified kind of media (audio or video).
///
/// The transceive will initialize a sender without a track. Pair this with `addTrack` to add a track to the sender later.
pub fn addTransceiverFromKind(pc: *PeerConnection, kind: webrtc.TrackKind, init_config: RtpTransceiver.Init) Error!RtpTransceiver {
    try pc.transceivers.ensureUnusedCapacity(pc.allocator, 1);

    var tr = InternalRtpTransceiver{
        .kind = kind,
        .direction = init_config.direction,
        .sender = .init(null),
        .receiver = .init(.init(kind, pc.random)),
    };

    if (init_config.stream_id) |stream_id| {
        const stream = try getOrAddStream(pc, stream_id);
        tr.sender.setStream(stream);
    }
    try pc.generateSsrc(&tr.sender);

    pc.transceivers.appendAssumeCapacity(tr);
    try pc.checkNegotiationNeeded();
    return pc.getRtpTransceiver(@intCast(pc.transceivers.items.len - 1));
}

pub const CreateOfferError = ClosedError || error{MidOverflow} || std.mem.Allocator.Error;

/// Creates a new offer.
///
/// Pointers are invalidated in the next call to `createOffer`.
pub fn createOffer(pc: *PeerConnection) CreateOfferError!webrtc.SessionDescription {
    try pc.checkNotClosed();

    const first_offer = pc.pending_local_description == null and pc.local_description == null;
    return if (first_offer) pc.createFirstOffer() else pc.createSubsequentOffer();
}

pub const CreateAnswerError = SignalingError || std.mem.Allocator.Error;

/// Creates an answer to a remote offer.
///
/// See [MDN RTCPeerConnection: createAnswer](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/createAnswer)
pub fn createAnswer(pc: *PeerConnection) CreateAnswerError!webrtc.SessionDescription {
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
            const tr = pc.findTransceiverByMid(media.mid).?;
            break :blk try tr.toSdpMediaAnswer(pc.allocator, media, pc.media_engine, pc.dtls_transport.ice_agent.getLocalCredentials());
        };
    }

    pc.writeSessionWithCandidates(&sdp_session, &w.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

    pc.last_answer.deinit(pc.allocator);
    pc.last_answer = .init(.answer, try w.toOwnedSlice(), sdp_session);
    return pc.last_answer.toSessionDescription();
}

pub const GetLocalDescriptionError = WriteLocalDescriptionError || std.mem.Allocator.Error;

/// Get local description.
///
/// This function allocates the sdp buffer inside the `webrtc.SessionDescription`. The caller owns
/// the buffer.
pub fn getLocalDescription(pc: *PeerConnection) GetLocalDescriptionError!?webrtc.SessionDescription {
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

pub const SetLocalDescriptionError = SignalingError || error{
    NotImplemented,
    TamperedOffer,
} || std.mem.Allocator.Error;

/// Apply a local description generated by `createOffer` or `createAnswer`.
///
/// For more details [MDN RTCPeerConnection: setLocalDescription](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/setLocalDescription)
pub fn setLocalDescription(pc: *PeerConnection, session_desc: webrtc.SessionDescription) SetLocalDescriptionError!void {
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

pub const SetRemoteDescriptionError = SignalingError || error{
    NotImplemented,
    InvalidAnswer,
} || SDPSession.Error;

/// Apply a remote description received from the remote peer.
pub fn setRemoteDescription(pc: *PeerConnection, session_desc: webrtc.SessionDescription, now: i64) SetRemoteDescriptionError!void {
    try pc.checkNotClosed();

    switch (session_desc.type) {
        .offer => switch (pc.signaling_state) {
            .have_remote_offer, .stable => try pc.applyRemoteDescription(&session_desc, now),
            else => return error.InvalidState,
        },
        .answer => switch (pc.signaling_state) {
            .have_local_offer => try pc.applyRemoteDescription(&session_desc, now),
            else => return error.InvalidState,
        },
        else => return error.NotImplemented,
    }
}

pub const WriteLocalDescriptionError = ClosedError || error{NoLocalDescription} || Io.Writer.Error;

/// Write the local description to a writer.
///
/// This will include the ICE candidates if they have been gathered.
pub fn writeLocalDescription(pc: *PeerConnection, w: *Io.Writer) WriteLocalDescriptionError!void {
    try pc.checkNotClosed();
    const sess_desc = pc.pending_local_description orelse pc.local_description;
    return if (sess_desc) |*desc| try pc.writeSessionWithCandidates(&desc.session, w) else error.NoLocalDescription;
}

pub const DataChannelError = DataChannel.CreateError;

pub fn getDataChannel(pc: *PeerConnection, id: DataChannel.ChannelId) DataChannel {
    std.debug.assert(id < pc.data_channels.items.len);
    return .{ .id = id, .pc = pc };
}

/// Create a new data channel.
pub fn createDataChannel(pc: *PeerConnection, label: []const u8, params: DataChannel.Parameters) DataChannelError!DataChannel {
    try pc.checkNotClosed();
    if (label.len > constants.max_data_channel_label_length) return error.LabelTooLong;
    if (params.protocol.len > constants.max_data_channel_label_length) return error.ProtocolTooLong;
    if (params.max_packet_lifetime != 0 and params.max_retransmits != 0) return error.InvalidParameters;
    if (params.id != null) return error.InvalidParameters;

    try pc.data_channels.ensureUnusedCapacity(pc.allocator, 1);
    var dc = try InternalDataChannel.init(pc.allocator, label, params);
    errdefer dc.deinit(pc.allocator);

    const channel_id: DataChannel.ChannelId = @intCast(pc.data_channels.items.len);

    if (pc.sctp_transport.connection_state == .connected) {
        dc.id = try pc.sctp_transport.openStream(channel_id, dc.buffered_amount_low_threshold);
    }

    pc.data_channels.appendAssumeCapacity(dc);
    errdefer _ = pc.data_channels.pop();

    const data_channel = pc.getDataChannel(channel_id);
    if (dc.id != null) try data_channel.connect(pc.int_buffers[packet_size..]);
    return data_channel;
}

/// Internal, use `DataChannel.send` or `DataChannel.sendText` instead.
pub fn sendDataChannelMessage(
    pc: *PeerConnection,
    channel_id: DataChannel.ChannelId,
    message: []const u8,
    is_binary: bool,
) DataChannel.SendError!void {
    const msg = try pc.getInternalDataChannel(channel_id).wrapMessage(message, is_binary);

    const max_message_size = pc.sctp_transport.max_message_size;
    if (max_message_size != 0 and message.len > max_message_size) return error.MessageTooLarge;

    pc.sctp_transport.handleWrite(msg) catch |err| switch (err) {
        error.AssocNotConnected => return error.DataChannelNotOpen,
        else => |e| return e,
    };
}

/// Internal, use `DataChannel.close` instead.
pub fn closeDataChannel(pc: *PeerConnection, channel_id: DataChannel.ChannelId) std.mem.Allocator.Error!void {
    const dc = pc.getInternalDataChannel(channel_id);
    if (dc.ready_state == .closing or dc.ready_state == .closed) return;

    const sid = dc.id orelse {
        try pc.events.pushBack(pc.allocator, .{ .data_channel = .{ .close = channel_id } });
        dc.ready_state = .closed;
        return;
    };
    try pc.sctp_transport.closeStream(sid);
    dc.ready_state = .closing;
}

pub fn close(pc: *PeerConnection) void {
    pc.dtls_transport.close();
    pc.closeDataChannels();
}

pub const ReadResult = union(enum) {
    rtp: struct { RtpReceiver, rtp.Packet },
    rtcp: RtcpIterator,
    app_data: SctpMessageIterator,
    none,
};

pub const RtcpIterator = struct {
    it: rtcp.CompoundPacketIterator,
    pc: *PeerConnection,

    pub fn init(pc: *PeerConnection, data: []const u8) RtcpIterator {
        return .{ .it = rtcp.CompoundPacketIterator.init(data), .pc = pc };
    }

    pub fn next(self: *RtcpIterator) !?struct { RtpSender, rtcp.Packet } {
        while (try self.it.next()) |packet| switch (packet.payload) {
            .nack => |nack| if (self.pc.findSenderBySsrc(nack.media_ssrc)) |sender_id| {
                try self.pc.transmits.pushBack(self.pc.allocator, .{ .nack = sender_id });
                _ = try self.pc.transceivers.items[sender_id].sender.handleRtcpNack(self.pc.allocator, nack);
                return .{ self.pc.getRtpSender(sender_id), packet };
            },
            .pli => |pli| if (self.pc.findSenderBySsrc(pli.media_ssrc)) |sender_id| return .{ self.pc.getRtpSender(sender_id), packet },
            else => |payload_type| Logger.debug("Received rtcp: {s}", .{@tagName(payload_type)}),
        };

        return null;
    }
};

pub const SctpMessageIterator = struct {
    sctp_it: SctpTransport.MessageIterator,
    pc: *PeerConnection,

    pub fn next(it: *SctpMessageIterator) std.mem.Allocator.Error!?DataChannel.UserMessage {
        const pc = it.pc;

        while (try it.sctp_it.next()) |msg| {
            switch (msg) {
                .open => |new_dc| {
                    var dc = new_dc;
                    errdefer dc.deinit(pc.allocator);

                    try pc.events.ensureUnusedCapacity(pc.allocator, 2);
                    try pc.data_channels.ensureUnusedCapacity(pc.allocator, 1);

                    const id: DataChannel.ChannelId = @intCast(pc.data_channels.items.len);
                    pc.sctp_transport.acceptStream(&dc, id) catch |err| switch (err) {
                        error.AssocNotConnected => {
                            dc.deinit(pc.allocator);
                            break;
                        },
                        else => |e| return e,
                    };

                    dc.ready_state = .open;
                    pc.data_channels.appendAssumeCapacity(dc);
                    pc.events.pushBackAssumeCapacity(.{ .data_channel = .{ .new = id } });
                    pc.events.pushBackAssumeCapacity(.{ .data_channel = .{ .open = id } });
                },
                .ack => |channel_id| _ = try pc.openDataChannel(channel_id),
                .message => |m| {
                    errdefer pc.allocator.free(m.data);
                    if (!try pc.openDataChannel(m.channel_id)) {
                        pc.allocator.free(m.data);
                        continue;
                    }
                    return .{ .channel_id = m.channel_id, .binary = m.binary, .data = m.data };
                },
            }
        }

        try pc.handleSctpTransportEvents();
        return null;
    }
};

/// Process a received datagram packet.
///
/// Not that in the case of RTP/RTCP packets, the packet is decrypted in place. Meaning that the data
/// slice will be modified and the caller should not use it after this call.
///
/// `app_data` returns data channel messages, if any. Also it drives the SCTP transport state machine, not
/// consuming the iterator will exercise backpressure on the SCTP association and data channels events will be stalled.
///
/// Invalid packets are discarded.
pub fn handleRead(pc: *PeerConnection, message: webrtc.TransportMessage, now: i64) std.mem.Allocator.Error!ReadResult {
    return pc.readMessage(message, now) catch |err| switch (err) {
        error.OutOfMemory => |e| e,
        else => {
            Logger.debug("Discarding invalid packet: {}", .{err});
            return .none;
        },
    };
}

pub fn handleTimeout(pc: *PeerConnection, now: i64, wall_clock_us: i64) std.mem.Allocator.Error!void {
    try pc.dtls_transport.handleTimeout(now);
    try pc.sctp_transport.handleTimeout(now);

    if (pc.connection_state == .connected and pc.sender_report_deadline == std.math.maxInt(i64)) {
        pc.sender_report_deadline = now + pc.random.intRangeAtMost(u16, 500, 1500);
    }

    if (now >= pc.sender_report_deadline) {
        pc.sender_report_deadline = now + pc.random.intRangeAtMost(u16, 500, 1500);
        pc.sender_report_it = .{ .timestamp = wall_clock_us };
    }
    if (pc.nack_generator) |*ng| ng.handleTimeout(now);
}

pub fn pollEvent(pc: *PeerConnection) ?Event {
    while (true) {
        const dtls_event = pc.dtls_transport.pollEvent() orelse return pc.events.popFront();
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

                    if (pc.connection_state == .closed) {
                        pc.signaling_state = .closed;
                        pc.closeDataChannels();
                    }
                    return .{ .connection_state = new_state };
                }
            },
            .ice_gathering_state => |state| return .{ .gathering_state = state },
        }
    }

    return pc.events.popFront();
}

pub const PollTransmitError = DtlsTransport.WriteMediaError;

pub fn pollTransmit(pc: *PeerConnection, buffer: []u8, now: i64) PollTransmitError!?webrtc.TransportMessage {
    const buffer2 = pc.int_buffers[packet_size .. 2 * packet_size];
    if (try pc.dtls_transport.pollTransmit(buffer)) |msg| return msg;

    if (try pc.sctp_transport.pollTransmit(buffer2, now)) |sctp_data| {
        return try pc.dtls_transport.writeAppData(sctp_data, buffer);
    }

    const payload = try pc.dtls_transport.rtpPayloadBuffer(buffer);

    if (pc.sender_report_it) |*it| {
        if (it.next(pc, payload)) |data| return try pc.dtls_transport.writeRtcp(buffer, data.len);
        pc.sender_report_it = null;
    }

    if (pc.nack_generator) |*ng| if (try ng.pollTransmit(payload[0..1200])) |data| {
        return try pc.dtls_transport.writeRtcp(buffer, data.len);
    };

    while (pc.transmits.front()) |entry| switch (entry) {
        .nack => |sender_id| {
            const sender = &pc.transceivers.items[sender_id].sender;
            const data = try sender.nextNack(payload) orelse {
                _ = pc.transmits.popFront();
                continue;
            };
            return try pc.dtls_transport.writeRtp(buffer, data.len);
        },
    };

    return null;
}

pub fn pollTimeout(pc: *PeerConnection) ?i64 {
    const dtls_timeout = pc.dtls_transport.pollTimeout() orelse std.math.maxInt(i64);
    const sctp_timeout = pc.sctp_transport.pollTimeout() orelse std.math.maxInt(i64);
    const nack_deadline = if (pc.nack_generator) |*ng| ng.pollTimeout() else std.math.maxInt(i64);
    const deadline = @min(@min(pc.sender_report_deadline, nack_deadline), @min(dtls_timeout, sctp_timeout));
    return if (deadline == std.math.maxInt(i64)) null else deadline;
}

pub const AddLocalCandidatesError = error{GatheringDone} || std.mem.Allocator.Error;

/// Adds local host addresses. The first call starts ICE gathering.
///
/// Gathering only completes once this is called with an empty list, so call
/// `addLocalCandidates(&.{}, now)` after all addresses and ICE servers are added.
pub fn addLocalCandidates(pc: *PeerConnection, addrs: []const Io.net.IpAddress, now: i64) AddLocalCandidatesError!void {
    try pc.dtls_transport.addIceLocalAddrs(addrs, now);
}

pub const AddIceServerError = ice.agent.AddServerError;

pub fn addIceServer(pc: *PeerConnection, local_addr: Io.net.IpAddress, server: ice.agent.Server, now: i64) AddIceServerError!void {
    try pc.dtls_transport.addIceServer(local_addr, server, now);
}

/// Internal, called by `RtpTransceiver.stop`.
pub fn checkNegotiationNeeded(pc: *PeerConnection) std.mem.Allocator.Error!void {
    if (pc.signaling_state != .stable) return;

    if (pc.isNegotiationNeeded()) {
        if (pc.negotiation_needed) return;
        try pc.events.pushBack(pc.allocator, .negotiation_needed);
        pc.negotiation_needed = true;
    } else {
        pc.negotiation_needed = false;
    }
}

fn getInternalDataChannel(pc: *PeerConnection, id: DataChannel.ChannelId) *InternalDataChannel {
    std.debug.assert(id < pc.data_channels.items.len);
    return &pc.data_channels.items[id];
}

fn closeDataChannels(pc: *PeerConnection) void {
    pc.sctp_transport.close();
    for (pc.data_channels.items) |*dc| dc.ready_state = .closed;
}

fn readMessage(pc: *PeerConnection, message: webrtc.TransportMessage, now: i64) !ReadResult {
    const data_event = (try pc.dtls_transport.handleRead(
        message,
        now,
        pc.int_buffers[0..packet_size],
    )) orelse {
        @branchHint(.unlikely);
        return .none;
    };

    return switch (data_event) {
        .rtp => |data| try pc.handleRtpData(data),
        .rtcp => |data| .{ .rtcp = .init(pc, data) },
        .app_data => |data| blk: {
            const sctp_it = try pc.sctp_transport.handleRead(data, now) orelse {
                try pc.handleSctpTransportEvents();
                break :blk .none;
            };
            break :blk .{ .app_data = .{ .sctp_it = sctp_it, .pc = pc } };
        },
    };
}

fn deinitDescriptions(pc: *PeerConnection, descriptions: []const *?ParsedSessionDescription) void {
    for (descriptions) |desc| if (desc.*) |*d| d.deinit(pc.allocator);
}

fn checkNotClosed(pc: *const PeerConnection) !void {
    if (pc.connection_state == .closed) return error.ConnectionClosed;
}

fn initTransceiverFromTrack(
    pc: *PeerConnection,
    track: webrtc.MediaStreamTrack,
    stream_id: ?[]const u8,
    added_by_add_track: bool,
) !RtpTransceiverID {
    try pc.transceivers.ensureUnusedCapacity(pc.allocator, 1);

    var tr = InternalRtpTransceiver{
        .kind = track.kind,
        .direction = .sendrecv,
        .sender = .init(track),
        .receiver = .init(track),
        .added_by_add_track = added_by_add_track,
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
    var w = Io.Writer.Allocating.init(pc.allocator);
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
        media.* = try tr.toSdpMedia(pc.allocator, pc.media_engine, pc.dtls_transport.ice_agent.getLocalCredentials());
        media.mid = try Mid.fromInt(mid);

        tr.sdp_mline_index = @intCast(medias.items.len - 1);
        mid +%= 1;
    }

    if (pc.hasDataChannels()) {
        try pc.initDataChannelMedia(medias.addOneAssumeCapacity());
    }

    pc.writeSessionWithCandidates(&sdp_session, &w.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

    pc.last_offer.deinit(pc.allocator);
    pc.last_offer = .init(.offer, try w.toOwnedSlice(), sdp_session);
    return pc.last_offer.toSessionDescription();
}

fn createSubsequentOffer(pc: *PeerConnection) !webrtc.SessionDescription {
    const sess_desc = pc.pending_local_description orelse pc.local_description.?;
    const remote_desc = pc.pending_remote_description orelse pc.remote_description;

    var sdp_session = try sess_desc.session.clone(pc.allocator);
    errdefer sdp_session.deinit(pc.allocator);

    var w = Io.Writer.Allocating.init(pc.allocator);
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
        media.* = try tr.toSdpMedia(pc.allocator, pc.media_engine, pc.dtls_transport.ice_agent.getLocalCredentials());
        media.mid = try Mid.fromInt(pc.mid);
        pc.mid +%= 1;
    };

    for (transceivers) |tr| if (tr.sdp_mline_index) |idx| {
        const media = &sdp_session.getMedias()[idx];
        media.port = if (tr.isStopped()) constants.sdp_rejected_port else constants.sdp_default_port;
        // TODO: other field to update
    };

    if (pc.hasDataChannels()) {
        if (app_media == null)
            try pc.initDataChannelMedia(try sdp_session.medias.addOne(pc.allocator))
        else
            app_media.?.port = constants.sdp_default_port;
    }

    pc.writeSessionWithCandidates(&sdp_session, &w.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

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

fn isNegotiationNeeded(pc: *const PeerConnection) bool {
    // TODO: Check ice restart
    const local_desc = pc.local_description orelse return false;
    const remote_desc = pc.remote_description orelse return false;
    for (pc.transceivers.items) |tr| {
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

fn writeSessionWithCandidates(pc: *PeerConnection, session: *const SDPSession, w: *Io.Writer) Io.Writer.Error!void {
    const ice_agent = &pc.dtls_transport.ice_agent;
    for (session.getMedias()) |*media| if (!media.isRejected()) {
        media.candidates = ice_agent.candidates[0..ice_agent.candidates_len];
        media.end_of_candidates = ice_agent.gathering_state == .complete;
        defer media.candidates = &.{};
        return session.write(w);
    };
    try session.write(w);
}

fn setSignalingState(pc: *PeerConnection, state: SignalingState) std.mem.Allocator.Error!void {
    if (pc.signaling_state == state) return;
    try pc.events.pushBack(pc.allocator, .{ .signaling_state = state });
    pc.signaling_state = state;
}

fn applyLocalOffer(pc: *PeerConnection, sess_desc: *const webrtc.SessionDescription) !void {
    if (!std.mem.eql(u8, pc.last_offer.sdp, sess_desc.sdp)) return error.TamperedOffer;
    try pc.events.ensureUnusedCapacity(pc.allocator, 1);

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
    try pc.setSignalingState(.have_local_offer);
}

fn applyLocalAnswer(pc: *PeerConnection, sess_desc: *const webrtc.SessionDescription) !void {
    if (!std.mem.eql(u8, pc.last_answer.sdp, sess_desc.sdp)) return error.TamperedOffer;
    const sdp_session = pc.last_answer.session;

    for (sdp_session.getMedias()) |*media| {
        if (media.port == 0 or media.isDataChannel()) continue;
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

    try pc.demuxer.updateMaps(&sdp_session, pc.transceivers.items);
    try pc.startRtpRtcpInterceptors();
    pc.maybeCloseSctpTransport(&sdp_session);

    pc.last_offer.deinit(pc.allocator);
    pc.pending_local_description = pc.last_answer;
    try pc.updateSignalingStateToStable();
}

fn applyRemoteDescription(pc: *PeerConnection, session_desc: *const webrtc.SessionDescription, now: i64) !void {
    const sdp_text = try pc.allocator.dupe(u8, session_desc.sdp);
    errdefer pc.allocator.free(sdp_text);

    var remote_sdp = try SDPSession.parse(pc.allocator, sdp_text);
    errdefer remote_sdp.deinit(pc.allocator);

    if (session_desc.type == .answer) {
        const local_session = pc.pending_local_description.?.session;
        if (remote_sdp.getMedias().len != local_session.getMedias().len) return error.InvalidAnswer;
    }

    var first_media: ?*SDPSession.Media = null;
    var track_events: std.ArrayList(InternalRtpTransceiver.TrackEventInit) = .empty;
    defer track_events.deinit(pc.allocator);
    if (session_desc.type == .offer) try pc.transceivers.ensureUnusedCapacity(pc.allocator, remote_sdp.getMedias().len);
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
                    const tr = pc.findTransceiverByMediaIndex(idx) orelse return error.InvalidSDP;
                    break :blk tr;
                },
                .offer => {
                    if (pc.findTransceiverByMid(media.mid)) |tr| break :blk tr;
                    for (pc.transceivers.items) |*tr| if (tr.canAssociateMedia(media)) break :blk tr;

                    const tr = InternalRtpTransceiver.initFromSdpMedia(media, pc.random, @intCast(idx));
                    pc.transceivers.appendAssumeCapacity(tr);
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
            const codecs = utils.intersectCodecs(remote_codecs, local_codecs) catch return error.InvalidSDP;

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
        const ice_agent = &pc.dtls_transport.ice_agent;
        // Set role on first remote offer.
        if (session_desc.type == .offer and ice_agent.getRemoteCredentials() == null) {
            ice_agent.role = if (remote_sdp.ice_lite) .controlling else .controlled;
        }

        try pc.dtls_transport.applyIceAttributes(media, &remote_sdp.fingerprint, now);
    }

    try pc.events.ensureUnusedCapacity(pc.allocator, track_events.items.len + 2);
    switch (session_desc.type) {
        .answer => {
            try pc.demuxer.updateMaps(&remote_sdp, pc.transceivers.items);
            try pc.startRtpRtcpInterceptors();
            pc.maybeCloseSctpTransport(&remote_sdp);

            pc.pending_remote_description = .init(.answer, sdp_text, remote_sdp);
            try pc.updateSignalingStateToStable();
        },
        .offer => {
            if (pc.pending_remote_description) |*desc| desc.deinit(pc.allocator);
            pc.pending_remote_description = .init(.offer, sdp_text, remote_sdp);
            try pc.setSignalingState(.have_remote_offer);
        },
        else => {},
    }

    for (track_events.items) |event| {
        const receiver_id: RtpReceiverID = blk: {
            for (pc.transceivers.items, 0..) |*tr, idx| if (tr == event.transceiver) break :blk @intCast(idx);
            unreachable;
        };

        pc.events.pushBackAssumeCapacity(.{ .track = .{
            .receiver = pc.getRtpReceiver(receiver_id),
            .track = event.track,
        } });
    }
}

fn updateSignalingStateToStable(pc: *PeerConnection) std.mem.Allocator.Error!void {
    try pc.events.ensureUnusedCapacity(pc.allocator, 2);
    pc.deinitDescriptions(&.{ &pc.local_description, &pc.remote_description });

    pc.local_description = pc.pending_local_description;
    pc.remote_description = pc.pending_remote_description;

    pc.pending_local_description = null;
    pc.pending_remote_description = null;

    pc.last_answer = .empty(.answer);
    pc.last_offer = .empty(.offer);

    try pc.setSignalingState(.stable);

    pc.negotiation_needed = false;
    try pc.checkNegotiationNeeded();
}

fn findTransceiverByMediaIndex(pc: *PeerConnection, index: usize) ?*InternalRtpTransceiver {
    for (pc.transceivers.items) |*tr| if (tr.sdp_mline_index) |tr_index| if (tr_index == index) return tr;
    return null;
}

fn findTransceiverByMid(pc: *PeerConnection, mid: Mid.Int) ?*InternalRtpTransceiver {
    for (pc.transceivers.items) |*tr| {
        if (tr.mid) |tr_mid| if (tr_mid == mid) return tr;
    }

    return null;
}

fn handleSctpTransportEvents(pc: *PeerConnection) std.mem.Allocator.Error!void {
    while (pc.sctp_transport.pollEvent()) |event| switch (event) {
        .connection_state => |state| switch (state) {
            .connected => for (pc.data_channels.items, 0..) |*dc, idx| {
                if (dc.id != null or dc.ready_state != .connecting) continue;
                dc.id = pc.sctp_transport.openStream(
                    @intCast(idx),
                    dc.buffered_amount_low_threshold,
                ) catch |err| switch (err) {
                    error.NoAvailableStreamId => {
                        try pc.events.pushBack(pc.allocator, .{ .data_channel = .{ .close = @intCast(idx) } });
                        dc.ready_state = .closed;
                        continue;
                    },
                    else => |e| return e,
                };
                try pc.getDataChannel(@intCast(idx)).connect(pc.int_buffers[packet_size..]);
            },
            .closed => for (pc.data_channels.items, 0..) |*dc, idx| {
                if (dc.ready_state == .closed) continue;
                try pc.events.pushBack(pc.allocator, .{ .data_channel = .{ .close = @intCast(idx) } });
                dc.ready_state = .closed;
            },
            else => {},
        },
        .buffered_amount_low_threshold => |channel_id| {
            try pc.events.pushBack(pc.allocator, .{ .data_channel = .{ .buffered_amount_low_threshold = channel_id } });
        },
        .channel_closing => |channel_id| {
            const dc = pc.getInternalDataChannel(channel_id);
            if (dc.ready_state == .open or dc.ready_state == .connecting) dc.ready_state = .closing;
        },
        .channel_closed => |channel_id| {
            const dc = pc.getInternalDataChannel(channel_id);
            if (dc.ready_state == .closed) continue;
            try pc.events.pushBack(pc.allocator, .{ .data_channel = .{ .close = channel_id } });
            dc.ready_state = .closed;
        },
    };
}

fn openDataChannel(pc: *PeerConnection, channel_id: DataChannel.ChannelId) std.mem.Allocator.Error!bool {
    const dc = pc.getInternalDataChannel(channel_id);
    switch (dc.ready_state) {
        .open, .closing => return true,
        .closed => return false,
        .connecting => {
            try pc.events.pushBack(pc.allocator, .{ .data_channel = .{ .open = channel_id } });
            dc.ready_state = .open;
            return true;
        },
    }
}

fn handleRtpData(pc: *PeerConnection, data: []const u8) !ReadResult {
    var packet = try rtp.Packet.parse(data);

    const id: u32 = switch (pc.demuxer.getTransceiver(&packet)) {
        .transceiver => |id| id,
        .mid => |mid| blk: {
            for (pc.transceivers.items, 0..) |tr, idx| if (tr.mid) |tr_mid| if (tr_mid == mid and !tr.isStopped()) {
                try pc.demuxer.cacheSsrc(packet.header.ssrc, @intCast(idx));
                break :blk @intCast(idx);
            };

            return .none;
        },
        .none => return .none,
    };

    const tr = &pc.transceivers.items[id];
    if (tr.receiver.handleRtpPacket(&packet)) {
        if (tr.receiver.nack) if (pc.nack_generator) |*nack_generator| try nack_generator.handleRead(&packet);
        return .{ .rtp = .{ pc.getRtpReceiver(id), packet } };
    }

    return .none;
}

fn findSenderBySsrc(pc: *PeerConnection, ssrc: u32) ?RtpSenderID {
    for (pc.transceivers.items, 0..) |tr, idx| if (tr.sender.ssrc == ssrc) return @intCast(idx);
    return null;
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
        pc.sctp_transport.max_message_size = remote.max_message_size orelse SctpTransport.default_max_message_size;
        try pc.sctp_transport.connect(pc.dtls_transport.getRole() == .server);
    };
}

fn startRtpRtcpInterceptors(pc: *PeerConnection) !void {
    // Nack generators
    var nack = false;
    for (pc.transceivers.items) |tr| {
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

fn generateSsrc(pc: *PeerConnection, sender: *InternalRtpSender) !void {
    sender.ssrc = try pc.demuxer.registerRandomSsrc(pc.random);
    sender.rtx_ssrc = try pc.demuxer.registerRandomSsrc(pc.random);
}

fn hasDataChannels(pc: *PeerConnection) bool {
    for (pc.data_channels.items) |*data_channel| {
        if (data_channel.ready_state != .closed) return true;
    }
    return false;
}

test {
    _ = @import("tests/peer_connection.zig");
    _ = @import("pc/demuxer.zig");
    _ = @import("pc/internal_rtp_sender.zig");
    _ = @import("pc/internal_rtp_receiver.zig");
    _ = @import("pc/internal_rtp_transceiver.zig");
    _ = @import("nack/send_buffer.zig");
    _ = @import("nack/receive_log.zig");
    _ = @import("nack/generator.zig");
    _ = @import("internal_data_channel.zig");
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
