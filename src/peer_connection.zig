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
const Demuxer = @import("pc/demuxer.zig");
const RtpTransceiver = @import("rtp_transceiver.zig");
const RtpSender = @import("rtp_sender.zig");
const Mid = @import("mid.zig");
const NackConfig = @import("pc/nack_config.zig");
const NackGenerator = @import("nack/generator.zig");
const PCHandler = @import("pc/handler.zig");
const DataChannel = @import("data_channel.zig");

const Io = std.Io;
const PeerConnection = @This();
const Logger = std.log.scoped(.pc);

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

pub const PeerConfiguration = struct {
    nack_config: NackConfig = .{},
};

pub const Config = struct {
    /// This is W3C's RTCConfiguration, which defines a set of parameters to configure the PeerConnection.
    rtc_configuration: RTCConfiguration = .{},
    /// This is the internal configuration for the PeerConnection, which defines a set of parameters to configure the PeerConnection.
    peer_config: PeerConfiguration = .{},
    /// The media engine used to advertise and negotiate codecs. Owned by the caller.
    media_engine: *webrtc.MediaEngine,
    handler: ?PCHandler = null,
};

allocator: std.mem.Allocator,
signaling_state: SignalingState,
connection_state: ConnectionState,
negotiation_needed: bool = false,

local_description: ?ParsedSessionDescription = null,
remote_description: ?ParsedSessionDescription = null,
pending_local_description: ?ParsedSessionDescription = null,
pending_remote_description: ?ParsedSessionDescription = null,
last_offer: ParsedSessionDescription = .empty(.offer),
last_answer: ParsedSessionDescription = .empty(.answer),

media_engine: *webrtc.MediaEngine,
handler: ?PCHandler,

streams: std.ArrayList(webrtc.MediaStream) = .empty,
transceivers: std.ArrayList(*webrtc.RtpTransceiver) = .empty,
dtls_transport: DtlsTransport,
sctp_transport: SctpTransport,
demuxer: Demuxer,

/// Used as a counter for generating mid values for transceivers.
mid: u16 = 0,

// RTP/RTCP interceptors
nack_config: NackConfig,
nack_generator: ?NackGenerator = null,

group: std.Io.Group = .init,
mutex: std.Io.Mutex = .init,

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

pub fn init(io: Io, allocator: std.mem.Allocator, config: Config) !PeerConnection {
    var dtls_transport: DtlsTransport = try .init(io, allocator, .{
        .ice_servers = config.rtc_configuration.ice_servers,
        .on_event = onDtlsEvent,
        .on_data = onDtlsData,
    });
    errdefer dtls_transport.deinit();

    return .{
        .signaling_state = .stable,
        .connection_state = .new,
        .allocator = allocator,
        .dtls_transport = dtls_transport,
        .demuxer = .init(allocator),
        .nack_config = config.peer_config.nack_config,
        .media_engine = config.media_engine,
        .handler = config.handler,
        .sctp_transport = SctpTransport.init(allocator, .{
            .local_port = constants.default_sctp_port,
            .remote_port = 0,
        }),
    };
}

pub fn deinit(pc: *PeerConnection) void {
    const io = pc.dtls_transport.getIo();
    pc.group.cancel(io);
    pc.handler = null;

    for (pc.transceivers.items) |tr| tr.deinit(io, pc.allocator);
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

    if (pc.nack_generator) |*ng| ng.deinit(io);
    pc.sctp_transport.deinit(pc.allocator);
    pc.dtls_transport.deinit();
    pc.demuxer.deinit();
}

/// Adds a new track to the PeerConnection and optionally associates it with a stream.
pub fn addTrack(pc: *PeerConnection, track: webrtc.MediaStreamTrack, stream_id: ?[]const u8) Error!*RtpSender {
    try pc.checkNotClosed();
    const io = pc.dtls_transport.getIo();

    const maybe_transceiver = blk: {
        pc.mutex.lockUncancelable(io);
        defer pc.mutex.unlock(io);

        for (pc.transceivers.items) |tr| if (tr.canAssociateTrack(track.kind)) {
            // We relaxed the canAssociateTrack check to allow reusing a transceiver even if the sender
            // already used for sending data. For that we need to reset the rtp sender.
            tr.sender.reset(io, pc.allocator);
            tr.setSenderTrack(track);
            try tr.sender.generateSsrc(io, &pc.demuxer);

            if (stream_id) |sid| {
                const stream = try getOrAddStream(pc, sid);
                tr.sender.setStream(stream);
            }

            break :blk tr;
        };

        break :blk null;
    };

    const tr = maybe_transceiver orelse try pc.initTransceiverFromTrack(track, stream_id, true);
    pc.checkNegotiationNeeded();
    return &tr.sender;
}

/// Removes a track from the PeerConnection.
///
/// Removing a track will update the transceiver's direction and stop sending media.
pub fn removeTrack(pc: *PeerConnection, sender: *RtpSender) !void {
    try pc.checkNotClosed();
    const tr: *webrtc.RtpTransceiver = @alignCast(@fieldParentPtr("sender", sender));
    tr.removeTrack();
    pc.checkNegotiationNeeded();
}

pub fn getTransceivers(pc: *const PeerConnection) []*RtpTransceiver {
    return pc.transceivers.items;
}

/// Creates a new transceiver to the PeerConnection from an existing track.
pub fn addTransceiverFromTrack(
    pc: *PeerConnection,
    track: webrtc.MediaStreamTrack,
    init_config: RtpTransceiver.Init,
) Error!*RtpTransceiver {
    const tr = try pc.initTransceiverFromTrack(track, init_config.stream_id, false);
    errdefer {
        tr.deinit(pc.dtls_transport.getIo(), pc.allocator);
        _ = pc.transceivers.swapRemove(pc.getTransceivers().len - 1);
    }

    tr.direction = init_config.direction;

    pc.checkNegotiationNeeded();
    return tr;
}

/// Creates a new transceiver to the PeerConnection from a specified kind of media (audio or video).
///
/// The transceive will initialize a sender without a track. Pair this with `addTrack` to add a track to the sender later.
pub fn addTransceiverFromKind(
    pc: *PeerConnection,
    kind: webrtc.TrackKind,
    init_config: RtpTransceiver.Init,
) Error!*RtpTransceiver {
    const io = pc.dtls_transport.getIo();
    const tr = try pc.allocator.create(RtpTransceiver);
    errdefer pc.allocator.destroy(tr);

    tr.* = .{
        .kind = kind,
        .direction = init_config.direction,
        .sender = .init(null),
        .receiver = webrtc.RtpReceiver.init(.init(io, kind)),
        .transport = &pc.dtls_transport,
    };

    if (init_config.stream_id) |stream_id| {
        const stream = try getOrAddStream(pc, stream_id);
        tr.sender.setStream(stream);
    }
    try tr.sender.generateSsrc(io, &pc.demuxer);

    try pc.appendTransceiver(tr);
    errdefer _ = pc.transceivers.swapRemove(pc.getTransceivers().len - 1);

    pc.checkNegotiationNeeded();
    return tr;
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
            new_media.setIceCredentials(pc.dtls_transport.ice_agent.localCredentials());
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
            break :blk try tr.toSdpMediaAnswer(pc.allocator, media, pc.media_engine);
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
pub fn createDataChannel(pc: *PeerConnection, label: []const u8, params: DataChannel.Parameters) !*DataChannel {
    try pc.checkNotClosed();
    if (label.len > constants.max_data_channel_label_length) return error.LabelTooLong;
    if (params.protocol.len > constants.max_data_channel_label_length) return error.ProtocolTooLong;
    if (params.max_packet_lifetime != 0 and params.max_retransmits != 0) return error.InvalidParameters;
    return try pc.sctp_transport.addDataChannel(pc.allocator, label, params);
}

pub fn close(pc: *PeerConnection) void {
    pc.dtls_transport.close();
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
) !*RtpTransceiver {
    const tr = try pc.allocator.create(RtpTransceiver);
    errdefer tr.deinit(pc.dtls_transport.getIo(), pc.allocator);

    tr.* = .{
        .kind = track.kind,
        .direction = .sendrecv,
        .sender = .init(track),
        .receiver = webrtc.RtpReceiver.init(track),
        .added_by_add_track = added_by_add_track,
        .transport = &pc.dtls_transport,
    };

    if (stream_id) |sid| {
        const stream = try getOrAddStream(pc, sid);
        tr.sender.setStream(stream);
    }
    try tr.sender.generateSsrc(pc.dtls_transport.getIo(), &pc.demuxer);

    try pc.appendTransceiver(tr);
    return tr;
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
    for (transceivers) |tr| {
        if (tr.stopping and tr.mid == null) continue;
        const media = try medias.addOne(pc.allocator);
        media.* = .empty;
        media.* = try tr.toSdpMedia(pc.allocator, pc.media_engine);
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
    for (transceivers) |tr| if (tr.sdp_mline_index == null) {
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

                    for (transceivers) |local_tr| if (local_tr.sdp_mline_index) |tr_idx| if (tr_idx == idx) {
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
        media.* = try tr.toSdpMedia(pc.allocator, pc.media_engine);
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
    media.setIceCredentials(pc.dtls_transport.ice_agent.localCredentials());
    pc.mid +%= 1;
}

fn checkNegotiationNeeded(pc: *PeerConnection) void {
    if (pc.signaling_state != .stable) return;

    if (pc.isNegotiationNeeded()) {
        if (pc.negotiation_needed) return;
        pc.negotiation_needed = true;
        if (pc.handler) |handler| handler.vtable.onNegotiationNeeded(handler.userdata);
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
    const io = pc.dtls_transport.getIo();

    if (maybe_media) |media| {
        ice_agent.mutex.lockUncancelable(io);
        defer ice_agent.mutex.unlock(io);

        media.candidates = ice_agent.localCandidates();
        media.end_of_candidates = ice_agent.gatheringState() == .complete;
        defer media.candidates = &.{};

        try sess_desc.session.write(w);
    } else try w.writeAll(sess_desc.sdp);
}

fn setSignalingState(pc: *PeerConnection, state: SignalingState) void {
    if (pc.signaling_state == state) return;
    pc.signaling_state = state;
    if (pc.handler) |handler| {
        handler.vtable.onSignalingStateChange(handler.userdata, state);
    }
}

fn applyLocalOffer(pc: *PeerConnection, sess_desc: *const webrtc.SessionDescription) !void {
    if (!std.mem.eql(u8, pc.last_offer.sdp, sess_desc.sdp)) return error.TamperedOffer;

    const offer = pc.last_offer.session;
    for (offer.getMedias(), 0..) |*media, idx| {
        if (media.isDataChannel()) continue;
        const transceiver = pc.findTransceiverByMediaIndex(idx).?;
        transceiver.mid = media.mid;
    }

    if (pc.dtls_transport.ice_agent.gatheringState() == .new) {
        try pc.dtls_transport.gatherCandidates(pc.last_offer.getIceRole());
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
            pc.dtls_transport.getIo(),
            pc.allocator,
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
        try pc.dtls_transport.gatherCandidates(pc.last_answer.getIceRole());
    }

    try pc.demuxer.updateMaps(pc.dtls_transport.getIo(), &sdp_session);
    try pc.startRtpRtcpInterceptors(renegotiation);
    pc.maybeCloseSctpTransport(&sdp_session);

    pc.last_offer.deinit(pc.allocator);
    pc.pending_local_description = pc.last_answer;
    pc.updateSignalingStateToStable();
}

fn applyRemoteDescription(pc: *PeerConnection, session_desc: *const webrtc.SessionDescription) !void {
    const io = pc.dtls_transport.getIo();
    const renegotiation = pc.remote_description != null;

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
                    {
                        pc.mutex.lockUncancelable(io);
                        defer pc.mutex.unlock(io);
                        for (pc.transceivers.items) |tr| if (tr.canAssociateMedia(media)) break :blk tr;
                    }

                    const tr = try RtpTransceiver.initFromSdpMedia(
                        pc.allocator,
                        io,
                        media,
                        @intCast(idx),
                    );
                    errdefer tr.deinit(io, pc.allocator);
                    tr.transport = &pc.dtls_transport;
                    try pc.appendTransceiver(tr);
                    break :blk tr;
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

            try transceiver.sender.setCodecs(io, pc.allocator, codecs.@"0", pc.nack_config.send_buffer_size);
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
        try pc.dtls_transport.applyIceAttributes(media);
        pc.dtls_transport.setPeerFingerprint(&remote_sdp.fingerprint);
    }

    switch (session_desc.type) {
        .answer => {
            try pc.demuxer.updateMaps(pc.dtls_transport.getIo(), &remote_sdp);
            try pc.startRtpRtcpInterceptors(renegotiation);
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

    for (track_events.items) |event| if (pc.handler) |handler| {
        handler.vtable.onTrack(handler.userdata, event);
    };
}

fn appendTransceiver(pc: *PeerConnection, tr: *RtpTransceiver) !void {
    const io = pc.dtls_transport.getIo();
    pc.mutex.lockUncancelable(io);
    defer pc.mutex.unlock(io);
    try pc.transceivers.append(pc.allocator, tr);
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
    pc.mutex.lockUncancelable(pc.dtls_transport.getIo());
    defer pc.mutex.unlock(pc.dtls_transport.getIo());
    for (pc.transceivers.items) |tr| if (tr.sdp_mline_index) |tr_index| if (tr_index == index) return tr;
    return null;
}

fn findTransceiverByMid(pc: *PeerConnection, mid: Mid.Int) ?*RtpTransceiver {
    pc.mutex.lockUncancelable(pc.dtls_transport.getIo());
    defer pc.mutex.unlock(pc.dtls_transport.getIo());
    for (pc.transceivers.items) |tr| {
        if (tr.mid) |tr_mid| if (tr_mid == mid) return tr;
    }

    return null;
}

fn onDtlsEvent(dtls_transport: *DtlsTransport, event: DtlsTransport.Event) void {
    const pc: *PeerConnection = @fieldParentPtr("dtls_transport", dtls_transport);

    switch (event) {
        .ice_candidate => |candidate| if (pc.handler) |handler| {
            handler.vtable.onIceCandidate(handler.userdata, candidate);
        },
        .ice_connection_state, .dtls_connection_state => {
            const ice_state, const dtls_state = pc.dtls_transport.getConnectionState();
            const new_state = nextPeerConnectionState(ice_state, dtls_state);
            if (new_state != pc.connection_state) {
                pc.connection_state = new_state;
                if (pc.connection_state == .connected) pc.maybeConnectSctpTransport() catch |err| {
                    Logger.err("Failed to connect SCTP transport: {}", .{err});
                };

                if (pc.connection_state == .closed) {
                    pc.group.cancel(pc.dtls_transport.getIo());
                    pc.setSignalingState(.closed);
                }
                if (pc.handler) |handler| handler.vtable.onConnectionStateChange(handler.userdata, new_state);
            }
        },
        .ice_gathering_state => |state| {
            if (pc.handler) |handler| handler.vtable.onGatheringStateChange(handler.userdata, state);
        },
    }
}

fn onDtlsData(dtls_transport: *DtlsTransport, data_event: DtlsTransport.DataEvent) void {
    const pc: *PeerConnection = @fieldParentPtr("dtls_transport", dtls_transport);
    switch (data_event) {
        .rtp => |data| pc.handleRtpData(data) catch {},
        .rtcp => |data| pc.handleRtcpData(data) catch {},
        .app_data => |data| pc.sctp_transport.handleIncomingData(data),
    }
}

fn handleRtcpData(pc: *PeerConnection, data: []const u8) !void {
    var it = rtcp.CompoundPacketIterator.init(data);
    while (try it.next()) |packet| switch (packet.payload) {
        .nack => |nack| if (pc.findSenderBySsrc(nack.media_ssrc)) |sender| try sender.handleNack(nack),
        else => {},
    };
}

fn handleRtpData(pc: *PeerConnection, data: []const u8) !void {
    const io = pc.dtls_transport.getIo();
    var packet = try rtp.Packet.parse(data);

    const mid = try pc.demuxer.getMid(io, &packet) orelse return;
    const tr = pc.findTransceiverByMid(mid) orelse return;

    if (try tr.receiver.handleRtpPacket(&packet)) {
        if (tr.receiver.nack) if (pc.nack_generator) |*nack_generator| {
            try nack_generator.handleRtpPacket(io, &packet);
        };
    }
}

fn findSenderBySsrc(pc: *PeerConnection, ssrc: u32) ?*RtpSender {
    pc.mutex.lockUncancelable(pc.dtls_transport.getIo());
    defer pc.mutex.unlock(pc.dtls_transport.getIo());
    for (pc.transceivers.items) |tr| if (tr.sender.ssrc == ssrc) return &tr.sender;
    return null;
}

fn writeIceCandidates(pc: *PeerConnection, w: *Io.Writer) !void {
    const ice_agent = &pc.dtls_transport.ice_agent;
    try ice_agent.mutex.lock(pc.dtls_transport.getIo());
    defer ice_agent.mutex.unlock(pc.dtls_transport.getIo());

    for (ice_agent.localCandidates()) |*candidate| {
        try w.print("a=candidate:{f}\r\n", .{candidate});
    }

    if (ice_agent.gatheringState() == .complete) {
        const attr: SDPAttribute = .end_of_candidates;
        try attr.write(w);
    }
}

// TODO: we keep it until we implement proper deletion
fn removeTransceivers(pc: *PeerConnection) void {
    if (pc.local_description == null or pc.remote_description == null) return;
    const local = pc.local_description.?.session;
    const remote = pc.remote_description.?.session;

    pc.mutex.lockUncancelable(pc.dtls_transport.getIo());
    defer pc.mutex.unlock(pc.dtls_transport.getIo());

    var idx: usize = 0;
    while (idx < pc.transceivers.items.len) {
        const tr = pc.transceivers.items[idx];
        if (tr.stopped and tr.mid != null and (local.getMedias()[tr.sdp_mline_index.?].port == 0 or
            remote.getMedias()[tr.sdp_mline_index.?].port == 0))
        {
            _ = pc.transceivers.orderedRemove(idx);
            tr.deinit(pc.dtls_transport.getIo(), pc.allocator);
            continue;
        }

        idx += 1;
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
        try pc.sctp_transport.connect(&pc.dtls_transport);
    };
}

fn startRtpRtcpInterceptors(pc: *PeerConnection, renegotiation: bool) !void {
    const io = pc.dtls_transport.getIo();

    // Init sender reports
    if (!renegotiation) {
        try pc.group.concurrent(io, struct {
            fn sendReports(p: *PeerConnection) !void {
                p.doSendReports() catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => |e| Logger.err("Error occurred while sending report: {}", .{e}),
                };
            }
        }.sendReports, .{pc});
    }

    // Nack generators
    var nack = false;
    try pc.mutex.lock(io);
    defer pc.mutex.unlock(io);

    for (pc.getTransceivers()) |tr| {
        if (tr.canReceive() and tr.receiver.nack) {
            nack = true;
            if (pc.nack_generator == null) {
                pc.nack_generator = .init(pc.allocator, .{
                    .size = pc.nack_config.receive_log_size,
                    .interval = pc.nack_config.interval,
                });
                try pc.nack_generator.?.start(&pc.dtls_transport);
            }
        } else {
            if (pc.nack_generator) |*ng| if (tr.receiver.ssrc) |ssrc| ng.deleteSource(io, ssrc);
        }
    }

    if (!nack) if (pc.nack_generator) |*nack_generator| {
        nack_generator.deinit(io);
        pc.nack_generator = null;
    };
}

fn doSendReports(pc: *PeerConnection) !void {
    const io = pc.dtls_transport.getIo();
    const seed = Io.Timestamp.now(io, .awake).toMicroseconds();
    var random = std.Random.DefaultPrng.init(@bitCast(seed));
    var r = random.random();

    while (true) {
        const sleep_ms = r.intRangeAtMost(u16, 500, 1000);
        try io.sleep(.fromMilliseconds(sleep_ms + 500), .awake);
        if (pc.connection_state != .connected) continue;

        const buffer = try pc.dtls_transport.ice_agent.createPacket();
        defer pc.dtls_transport.ice_agent.destroyPacket(buffer);
        const timestamp = Io.Timestamp.now(io, .real).toMicroseconds();

        try pc.mutex.lock(io);
        defer pc.mutex.unlock(io);
        for (pc.getTransceivers()) |tr| {
            if (tr.isStopped() or tr.direction == .inactive) continue;

            // Logger.debug("send rtcp report for transceiver: {?s}", .{tr.mid});
            const data = tr.getRtcpReport(io, timestamp, buffer);
            if (data.len == 0) continue;
            try pc.dtls_transport.sendRtcp(data);
        }
    }
}

test {
    _ = @import("tests/peer_connection.zig");
    _ = @import("pc/demuxer.zig");
    _ = @import("dtls/dtls.zig");
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
