const std = @import("std");
const ice = @import("ice");
const rtp = @import("rtp");
const rtcp = @import("rtcp");
const utils = @import("utils.zig");
const SDPAttribute = @import("sdp").Attribute.ParsedAttribute;

const dtls = @import("dtls/dtls.zig");
const DtlsTransport = @import("dtls_transport.zig");
const webrtc = @import("webrtc.zig");
const SDPSession = @import("sdp_session.zig");
const Demuxer = @import("pc/demuxer.zig");

const Io = std.Io;
const PeerConnection = @This();
const Logger = std.log.scoped(.pc);

pub const Error = error{
    InvalidState,
    QueueClosed,
    /// Returned when an ssrc cannot be
    /// generated for a sender
    SsrcUnavailable,
} || std.mem.Allocator.Error;

pub const Event = union(enum) {
    negotiation_needed: void,
    signaling_state: webrtc.SignalingState,
    connection_state: webrtc.ConnectionState,
    track_event: webrtc.TrackEventInit,
    rtp: rtp.Packet,
    rtcp: []const u8,
};

allocator: std.mem.Allocator,
signaling_state: webrtc.SignalingState,
connection_state: webrtc.ConnectionState,
negotiation_needed: bool = false,

local_description: ?ParsedSesssionDescription = null,
remote_description: ?ParsedSesssionDescription = null,
pending_local_description: ?ParsedSesssionDescription = null,
pending_remote_description: ?ParsedSesssionDescription = null,
last_offer: ParsedSesssionDescription = .empty(.offer),
last_answer: ParsedSesssionDescription = .empty(.answer),

transceivers: std.ArrayList(*webrtc.RtpTransceiver) = .empty,
dtls_transport: DtlsTransport,
demuxer: Demuxer,

/// Used as a counter for generating mid values for transceivers.
mid: u16 = 0,

queue_buffer: []Event,
queue: Io.Queue(Event),
group: std.Io.Group = .init,

pub const Config = struct {
    inner_queue_size: u8 = 5,
};

const ParsedSesssionDescription = struct {
    desc_type: webrtc.SessionDescriptionType,
    sdp: []const u8,
    session: SDPSession,

    fn empty(desc_type: webrtc.SessionDescriptionType) ParsedSesssionDescription {
        return .{
            .desc_type = desc_type,
            .sdp = &.{},
            .session = .empty,
        };
    }

    fn deinit(sess_desc: *ParsedSesssionDescription, allocator: std.mem.Allocator) void {
        allocator.free(sess_desc.sdp);
        sess_desc.session.deinit(allocator);
    }

    fn toSessionDescription(sess_desc: *const ParsedSesssionDescription) webrtc.SessionDescription {
        return .{
            .type = sess_desc.desc_type,
            .sdp = sess_desc.sdp,
        };
    }

    fn getIceRole(sess_desc: *const ParsedSesssionDescription) ice.Role {
        if (sess_desc.desc_type == .offer or sess_desc.session.ice_lite) return .controlling;
        return .controlled;
    }
};

pub fn init(io: Io, allocator: std.mem.Allocator, config: Config) !PeerConnection {
    var dtls_transport: DtlsTransport = try .init(io, allocator, .{});
    errdefer dtls_transport.deinit();

    const queue_buffer = try allocator.alloc(Event, config.inner_queue_size);

    return .{
        .signaling_state = .stable,
        .connection_state = .new,
        .allocator = allocator,
        .dtls_transport = dtls_transport,
        .demuxer = .init(allocator),
        .queue_buffer = queue_buffer,
        .queue = .init(queue_buffer),
    };
}

pub fn deinit(pc: *PeerConnection) void {
    const io = pc.dtls_transport.getIo();
    pc.group.cancel(io);
    pc.queue.close(io);
    pc.allocator.free(pc.queue_buffer);

    for (pc.transceivers.items) |tr| tr.deinit(pc.allocator);
    pc.transceivers.deinit(pc.allocator);

    if (pc.local_description) |*local_desc| local_desc.deinit(pc.allocator);
    if (pc.remote_description) |*remote_desc| remote_desc.deinit(pc.allocator);
    if (pc.pending_local_description) |*local_desc| local_desc.deinit(pc.allocator);
    if (pc.pending_remote_description) |*remote_desc| remote_desc.deinit(pc.allocator);

    pc.last_offer.deinit(pc.allocator);
    pc.last_answer.deinit(pc.allocator);

    pc.dtls_transport.deinit();
    pc.demuxer.deinit();
}

pub fn addTrack(pc: *PeerConnection, track: webrtc.MediaStreamTrack) Error!*webrtc.RtpSender {
    try pc.checkNotClosed();

    const maybe_transceiver = blk: {
        for (pc.transceivers.items) |tr| if (tr.canAssociateTrack(track.kind)) {
            tr.setSenderTrack(track);
            break :blk tr;
        };

        break :blk null;
    };

    const tr = maybe_transceiver orelse try pc.initTransceiverFromTrack(track, true);
    try pc.checkNegotiationNeeded();
    return &tr.sender;
}

pub fn removeTrack(pc: *PeerConnection, sender: *webrtc.RtpSender) !void {
    try pc.checkNotClosed();
    const tr: *webrtc.RtpTransceiver = @alignCast(@fieldParentPtr("sender", sender));
    if (tr.stopping or sender.track == null) return;
    tr.sender.track = null;
    switch (tr.direction) {
        .sendrecv => tr.direction = .recvonly,
        .sendonly => tr.direction = .inactive,
        else => {},
    }

    try pc.checkNegotiationNeeded();
}

pub const AddTransceiverInit = struct {
    direction: webrtc.Direction,
};

pub inline fn getTransceivers(pc: *const PeerConnection) []*webrtc.RtpTransceiver {
    return pc.transceivers.items;
}

pub fn addTransceiverFromTrack(
    pc: *PeerConnection,
    track: webrtc.MediaStreamTrack,
    init_config: AddTransceiverInit,
) Error!*webrtc.RtpTransceiver {
    const tr = try pc.initTransceiverFromTrack(track, false);
    errdefer {
        pc.allocator.destroy(tr);
        _ = pc.transceivers.swapRemove(pc.getTransceivers().len - 1);
    }

    tr.direction = init_config.direction;
    try pc.checkNegotiationNeeded();
    return tr;
}

pub fn addTransceiverFromKind(
    pc: *PeerConnection,
    kind: webrtc.TrackKind,
    init_config: AddTransceiverInit,
) Error!*webrtc.RtpTransceiver {
    const io = pc.dtls_transport.getIo();
    const tr = try pc.allocator.create(webrtc.RtpTransceiver);
    errdefer pc.allocator.destroy(tr);

    try pc.transceivers.append(pc.allocator, tr);
    errdefer _ = pc.transceivers.swapRemove(pc.getTransceivers().len - 1);

    tr.* = .{
        .kind = kind,
        .direction = init_config.direction,
        .sender = .init(null),
        .receiver = .init(.init(io, kind)),
        .transport = &pc.dtls_transport,
    };
    tr.sender.ssrc = try generateSsrc(io, &pc.demuxer);
    try pc.checkNegotiationNeeded();
    return tr;
}

fn initTransceiverFromTrack(pc: *PeerConnection, track: webrtc.MediaStreamTrack, added_by_add_track: bool) !*webrtc.RtpTransceiver {
    const tr = try pc.allocator.create(webrtc.RtpTransceiver);
    errdefer pc.allocator.destroy(tr);
    try pc.transceivers.append(pc.allocator, tr);

    tr.* = .{
        .kind = track.kind,
        .direction = .sendrecv,
        .sender = .init(track),
        .receiver = .init(track),
        .added_by_add_track = added_by_add_track,
        .transport = &pc.dtls_transport,
    };
    tr.sender.ssrc = try generateSsrc(pc.dtls_transport.getIo(), &pc.demuxer);

    return tr;
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
    if (pc.signaling_state != .have_remote_offer and pc.signaling_state != .have_local_pranswer)
        return error.InvalidState;

    const offer = pc.pending_remote_description.?;
    var w = Io.Writer.Allocating.init(pc.allocator);
    defer w.deinit();

    var sdp_session: SDPSession = .empty;
    errdefer sdp_session.deinit(pc.allocator);

    sdp_session.medias = try .initCapacity(pc.allocator, offer.session.getMedias().len);
    pc.dtls_transport.session.getFingerprint(&sdp_session.fingerprint);

    var idx: usize = 0;
    for (offer.session.getMedias()) |*media| {
        const tr = pc.findTransceiverByMediaIndex(idx) orelse return error.Unexpected;
        if (media.isRejected()) {
            var new_media = try media.clone(pc.allocator);
            new_media.bundle_only = false;
        } else {
            const codecs = try utils.getCodecIntersection(
                pc.allocator,
                media.rtp_codec_parameters,
                webrtc.getCodecCapabilities(tr.kind),
            );
            var new_media = sdp_session.medias.addOneAssumeCapacity();
            new_media.* = .empty;
            new_media.kind = tr.kind;
            new_media.port = if (codecs.len == 0) 0 else 9;
            new_media.rtcp_mux = true;
            new_media.rtcp_rsize = false;
            new_media.setup = .active;
            new_media.direction = media.direction.reverse().intersect(tr.direction);
            new_media.rtp_codec_parameters = if (new_media.port == 0)
                try pc.allocator.dupe(webrtc.RtpCodecParameters, media.rtp_codec_parameters)
            else
                codecs;
            @memcpy(new_media.mid[0..tr.mid.?.len], tr.mid.?);
            new_media.setIceCredentials(pc.dtls_transport.ice_agent.credentials);
        }

        idx += 1;
    }

    try sdp_session.write(&w.writer);

    const answer_sdp = try w.toOwnedSlice();
    pc.last_answer.deinit(pc.allocator);
    pc.last_answer = .{
        .desc_type = .answer,
        .sdp = answer_sdp,
        .session = sdp_session,
    };

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
pub fn getRemoteDescription(pc: *PeerConnection) !?webrtc.SessionDescription {
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

pub fn writeLocalDescription(pc: *PeerConnection, w: *Io.Writer) !void {
    try pc.checkNotClosed();
    const sess_desc = pc.pending_local_description orelse pc.local_description;
    return if (sess_desc) |*desc| try pc.writeDescriptionWithCandidates(desc, w) else error.NoLocalDescription;
}

pub fn poll(pc: *PeerConnection) !Event {
    try pc.checkNotClosed();
    const io = pc.dtls_transport.getIo();
    while (pc.queue.getOne(io)) |event| switch (event) {
        .connection_state => |state| switch (state) {
            .closed => {
                pc.queue.close(io);
                pc.group.cancel(io);
                return event;
            },
            else => return event,
        },
        else => return event,
    } else |err| return err;
}

pub fn destroyPacket(pc: *PeerConnection, rtp_packet: *const rtp.Packet) void {
    const header_size: u8 = @intCast(rtp_packet.size() - rtp_packet.payload.len);
    const beg = rtp_packet.payload.ptr - header_size;
    pc.dtls_transport.ice_agent.destroyPacket(beg[0..1]);
}

pub fn close(pc: *PeerConnection) void {
    pc.dtls_transport.close();
}

fn checkNotClosed(pc: *const PeerConnection) !void {
    if (pc.connection_state == .closed) return error.InvalidState;
}

fn createFirstOffer(pc: *PeerConnection) !webrtc.SessionDescription {
    var w = std.Io.Writer.Allocating.init(pc.allocator);
    errdefer w.deinit();

    var sdp_session: SDPSession = .empty;
    errdefer sdp_session.deinit(pc.allocator);
    pc.dtls_transport.session.getFingerprint(&sdp_session.fingerprint);

    const transceivers = pc.transceivers.items;
    sdp_session.medias = try .initCapacity(pc.allocator, transceivers.len);
    var medias = &sdp_session.medias;

    var mid = pc.mid;
    for (transceivers) |tr| {
        if (tr.stopping and tr.mid == null) continue;
        const media = try medias.addOne(pc.allocator);
        media.* = .empty;
        media.* = try tr.toSdpMedia(pc.allocator);
        _ = try std.fmt.bufPrint(&media.mid, "{}", .{mid});

        tr.sdp_mline_index = @intCast(medias.items.len - 1);
        mid +%= 1;
    }

    try sdp_session.write(&w.writer);

    pc.last_offer.deinit(pc.allocator);
    pc.last_offer = .{
        .desc_type = .offer,
        .sdp = try w.toOwnedSlice(),
        .session = sdp_session,
    };

    return pc.last_offer.toSessionDescription();
}

fn createSubsequentOffer(pc: *PeerConnection) !webrtc.SessionDescription {
    const sess_desc = pc.pending_local_description orelse pc.local_description.?;
    const remote_desc = pc.pending_remote_description orelse pc.remote_description;

    var sdp_session = try sess_desc.session.clone(pc.allocator);
    errdefer sdp_session.deinit(pc.allocator);

    var w = std.Io.Writer.Allocating.init(pc.allocator);
    errdefer w.deinit();

    const transceivers = pc.transceivers.items;
    for (transceivers) |tr| if (tr.sdp_mline_index == null) {
        if (tr.isStopped()) continue;
        // Check if we can recycle a media
        const media = blk: {
            for (sdp_session.getMedias(), 0..) |*media, idx| {
                const remote_rejected = remote_desc != null and remote_desc.?.session.getMedias()[idx].port == 0;
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
        media.* = try tr.toSdpMedia(pc.allocator);
        _ = try std.fmt.bufPrint(&media.mid, "{}", .{pc.mid});
        pc.mid +%= 1;
    };

    for (transceivers) |tr| if (tr.sdp_mline_index) |idx| {
        const media = &sdp_session.getMedias()[idx];
        media.port = if (tr.isStopped()) 0 else 9;
        // TODO: other field to update
    };

    try sdp_session.write(&w.writer);
    try pc.writeIceCandidates(&w.writer);

    pc.last_offer.deinit(pc.allocator);
    pc.last_offer = .{
        .desc_type = .offer,
        .sdp = try w.toOwnedSlice(),
        .session = sdp_session,
    };

    return pc.last_offer.toSessionDescription();
}

fn checkNegotiationNeeded(pc: *PeerConnection) !void {
    if (pc.signaling_state != .stable) return;

    if (pc.isNegotiationNeeded()) {
        if (pc.negotiation_needed) return;
        pc.negotiation_needed = true;
        pc.queue.putOne(pc.dtls_transport.getIo(), .negotiation_needed) catch return error.QueueClosed;
    } else {
        pc.negotiation_needed = false;
    }
}

fn isNegotiationNeeded(pc: *const PeerConnection) bool {
    // TODO: Check ice restart
    const local_desc = pc.local_description orelse return false;
    const remote_desc = pc.local_description orelse return false;
    for (pc.getTransceivers()) |tr| {
        if (tr.stopping and tr.direction != .stopped) return true;
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

fn updateState(pc: *PeerConnection) !void {
    const old_state = pc.connection_state;
    const ice_state, const dtls_state = pc.dtls_transport.getConnectionState();

    if (ice_state == .closed)
        pc.connection_state = .closed
    else if (ice_state == .failed or dtls_state == .failed)
        pc.connection_state = .failed
    else if (ice_state == .disconnected)
        pc.connection_state = .disconnected
    else if (ice_state == .new and (dtls_state == .new or dtls_state == .closed))
        pc.connection_state = .new
    else if ((ice_state == .connected or ice_state == .completed) and (dtls_state == .connected or dtls_state == .closed))
        pc.connection_state = .connected
    else
        pc.connection_state = .connecting;

    if (pc.connection_state != old_state)
        try pc.queue.putOne(pc.dtls_transport.getIo(), .{ .connection_state = pc.connection_state });
}

fn writeDescriptionWithCandidates(pc: *PeerConnection, sess_desc: *const ParsedSesssionDescription, w: *Io.Writer) !void {
    const sdp = sess_desc.sdp;
    var second_pos: ?usize = null;
    const first_pos = std.mem.find(u8, sdp, "\nm=");
    if (first_pos) |pos| second_pos = std.mem.findPos(u8, sdp, pos + 3, "\nm=");

    if (second_pos) |pos| {
        try w.writeAll(sdp[0 .. pos + 1]);
        try pc.writeIceCandidates(w);
        try w.writeAll(sdp[pos + 1 ..]);
    } else if (first_pos != null) {
        try w.writeAll(sdp);
        try pc.writeIceCandidates(w);
    } else {
        try w.writeAll(sdp);
    }
}

fn applyLocalOffer(pc: *PeerConnection, sess_desc: *const webrtc.SessionDescription) !void {
    if (!std.mem.eql(u8, pc.last_offer.sdp, sess_desc.sdp)) return error.TamperedOffer;

    const offer = pc.last_offer.session;
    for (offer.getMedias(), 0..) |*media, idx| {
        const transceiver = pc.findTransceiverByMediaIndex(idx).?;
        transceiver.mid = &media.mid;
    }

    if (pc.dtls_transport.ice_agent.gathering_state == .new) {
        try pc.group.concurrent(pc.dtls_transport.getIo(), pollTransportWrapper, .{pc});
        try pc.dtls_transport.gatherCandidates(pc.last_offer.getIceRole());
    }

    if (pc.pending_local_description) |*desc| desc.deinit(pc.allocator);
    pc.signaling_state = .have_local_offer;
    pc.pending_local_description = pc.last_offer;
    pc.last_offer = .empty(.offer);
    pc.mid +%= @intCast(offer.getMedias().len);

    try pc.queue.putOne(pc.dtls_transport.getIo(), .{ .signaling_state = pc.signaling_state });
}

fn applyLocalAnswer(pc: *PeerConnection, sess_desc: *const webrtc.SessionDescription) !void {
    if (!std.mem.eql(u8, pc.last_answer.sdp, sess_desc.sdp)) return error.TamperedOffer;
    const sdp_session = pc.last_answer.session;
    const renegotiation = pc.local_description != null;

    var media_exists: bool = false;
    for (sdp_session.getMedias()) |*media| {
        const tr = pc.findTransceiverByMid(&media.mid).?;
        if (media.port == 0) {
            continue;
        }

        media_exists = true;

        tr.current_direction = media.direction;
        tr.fired_direction = media.direction;
        tr.sender.codecs = media.rtp_codec_parameters;
        tr.receiver.codecs = media.rtp_codec_parameters;
        // TODO: track removal
    }

    // if there's no negotiated media, don't start connectivity checks
    if (media_exists and !renegotiation) {
        try pc.group.concurrent(pc.dtls_transport.getIo(), pollTransportWrapper, .{pc});
        try pc.dtls_transport.gatherCandidates(pc.last_answer.getIceRole());
    }
    try pc.demuxer.updateMaps(&sdp_session);

    pc.pending_local_description = pc.last_answer;
    try pc.updateSignalingStateToStable();
    pc.removeTransceivers();
    try pc.startSenderReports();
}

fn applyRemoteDescription(pc: *PeerConnection, session_desc: *const webrtc.SessionDescription) !void {
    const sdp_text = try pc.allocator.dupe(u8, session_desc.sdp);
    errdefer pc.allocator.free(sdp_text);

    var remote_sdp = try SDPSession.parse(pc.allocator, sdp_text);
    errdefer remote_sdp.deinit(pc.allocator);

    if (session_desc.desc_type == .answer) {
        const local_session = pc.pending_local_description.?.session;
        if (remote_sdp.getMedias().len != local_session.getMedias().len) return error.InvalidAnswer;
    }

    // TODO: validate rtp header extensions and add them to transceivers
    // TODO: Add ssrc to demuxer
    // TODO: Add rtcp feedback

    var first_media: ?*SDPSession.SDPMedia = null;
    var track_events: std.ArrayList(webrtc.TrackEventInit) = .empty;
    defer track_events.deinit(pc.allocator);
    for (remote_sdp.getMedias(), 0..) |*media, idx| {
        var transceiver = blk: {
            switch (session_desc.type) {
                .answer => {
                    const tr = pc.findTransceiverByMediaIndex(idx) orelse return error.NotExistingTransceiver;
                    break :blk tr;
                },
                .offer => {
                    if (pc.findTransceiverByMediaIndex(idx)) |tr| break :blk tr;
                    for (pc.transceivers.items) |tr| if (tr.canAssociateMedia(media)) break :blk tr;

                    const tr = try webrtc.RtpTransceiver.initFromSdpMedia(
                        pc.allocator,
                        pc.dtls_transport.getIo(),
                        media,
                        @intCast(idx),
                    );
                    errdefer tr.deinit(pc.allocator);
                    tr.transport = &pc.dtls_transport;
                    try pc.transceivers.append(pc.allocator, tr);
                    break :blk tr;
                },
                else => unreachable,
            }
        };

        transceiver.mid = &media.mid;
        transceiver.sdp_mline_index = @intCast(idx);

        if (media.isRejected()) {
            if (!transceiver.stopping) transceiver.stop();
            transceiver.direction = .stopped;
            transceiver.current_direction = null;
            continue;
        }

        first_media = first_media orelse media;

        const direction = media.direction.reverse();
        switch (direction) {
            .recvonly, .sendrecv => {}, // TODO: get msids from sdp and associate with receiver track
            else => {},
        }
        transceiver.current_direction = direction;

        if (session_desc.type == .answer) {
            const local_sdp = pc.pending_local_description.?.session;
            const local_codecs = local_sdp.getMedias()[idx].rtp_codec_parameters;
            const remote_codecs = media.rtp_codec_parameters;
            const codecs = try utils.intersectCodecs(remote_codecs, local_codecs);

            transceiver.sender.codecs = codecs.@"0";
            transceiver.receiver.codecs = codecs.@"1";
        }

        if (transceiver.processRemoteTrack(direction)) |track_init_event| {
            try track_events.append(pc.allocator, track_init_event);
        }
    }

    if (first_media) |media| {
        try pc.dtls_transport.applyIceAttributes(media);
        pc.dtls_transport.setPeerFingerprint(&remote_sdp.fingerprint);
    }

    switch (session_desc.type) {
        .answer => {
            try pc.demuxer.updateMaps(&remote_sdp);
            pc.pending_remote_description = .{
                .desc_type = .answer,
                .sdp = sdp_text,
                .session = remote_sdp,
            };
            try pc.updateSignalingStateToStable();
            pc.removeTransceivers();
            try pc.startSenderReports();
        },
        .offer => {
            pc.pending_remote_description = .{
                .desc_type = .offer,
                .sdp = sdp_text,
                .session = remote_sdp,
            };
            pc.signaling_state = .have_remote_offer;
            try pc.queue.putOne(pc.dtls_transport.getIo(), .{ .signaling_state = pc.signaling_state });
        },
        else => {},
    }

    for (track_events.items) |event|
        try pc.queue.putOne(pc.dtls_transport.getIo(), .{ .track_event = event });
}

fn updateSignalingStateToStable(pc: *PeerConnection) !void {
    pc.signaling_state = .stable;

    if (pc.local_description) |*local_desc| local_desc.deinit(pc.allocator);
    if (pc.remote_description) |*remote_desc| remote_desc.deinit(pc.allocator);

    pc.local_description = pc.pending_local_description;
    pc.remote_description = pc.pending_remote_description;

    pc.pending_local_description = null;
    pc.pending_remote_description = null;

    pc.last_answer = .empty(.answer);
    pc.last_offer = .empty(.offer);

    try pc.queue.putOne(pc.dtls_transport.getIo(), .{ .signaling_state = pc.signaling_state });

    pc.negotiation_needed = false;
    try pc.checkNegotiationNeeded();
}

fn findTransceiverByMediaIndex(pc: *PeerConnection, index: usize) ?*webrtc.RtpTransceiver {
    for (pc.transceivers.items) |transceiver| if (transceiver.sdp_mline_index) |tr_index| if (tr_index == index)
        return transceiver;

    return null;
}

fn findTransceiverByMid(pc: *PeerConnection, mid: []const u8) ?*webrtc.RtpTransceiver {
    for (pc.transceivers.items) |transceiver| if (transceiver.mid) |tr_mid| if (std.mem.eql(u8, tr_mid, mid))
        return transceiver;

    return null;
}

fn pollTransportWrapper(pc: *PeerConnection) !void {
    pc.pollTransport() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => std.log.err("Failed to poll transport event: {}", .{err}),
    };
}

fn pollTransport(pc: *PeerConnection) !void {
    const io = pc.dtls_transport.getIo();

    while (pc.dtls_transport.poll()) |event| switch (event) {
        .ice_candidate => |candidate| if (candidate) |c| Logger.debug("candidate:{f}", .{c}),
        .ice_connection_state, .dtls_connection_state => {
            try pc.updateState();
            if (pc.connection_state == .closed) {
                pc.signaling_state = .closed;
                return;
            }
        },
        .rtcp => |data| {
            Logger.debug("Decrypted rtcp packet: {x}", .{data});
            pc.dtls_transport.ice_agent.destroyPacket(data);
        },
        .rtp => |data| {
            if (pc.handleRtpPacket(data) catch {
                pc.dtls_transport.ice_agent.destroyPacket(data);
                continue;
            }) |rtp_event| {
                try pc.queue.putOne(io, rtp_event);
                continue;
            }

            pc.dtls_transport.ice_agent.destroyPacket(data);
        },
    } else |err| return err;
}

fn handleRtpPacket(pc: *PeerConnection, data: []const u8) !?Event {
    const packet = try rtp.Packet.parse(data);
    if (try pc.demuxer.getMid(&packet)) |mid| if (pc.findTransceiverByMid(mid)) |tr| {
        if (try tr.receiver.handleRtpPacket(packet)) |p| {
            return .{ .rtp = p };
        }
    };

    return null;
}

fn writeIceCandidates(pc: *PeerConnection, w: *Io.Writer) !void {
    const ice_agent = &pc.dtls_transport.ice_agent;
    try ice_agent.mutex.lock(pc.dtls_transport.getIo());
    defer ice_agent.mutex.unlock(pc.dtls_transport.getIo());

    for (ice_agent.candidates.items) |*candidate| {
        try w.print("a=candidate:{f}\r\n", .{candidate});
    }

    if (ice_agent.gathering_state == .complete) {
        const attr: SDPAttribute = .end_of_candidates;
        try attr.write(w);
    }
}

fn removeTransceivers(pc: *PeerConnection) void {
    if (pc.local_description == null or pc.remote_description == null) return;
    const local = pc.local_description.?.session;
    const remote = pc.remote_description.?.session;

    var idx: usize = 0;
    while (idx < pc.transceivers.items.len) {
        const tr = pc.transceivers.items[idx];
        if (tr.direction == .stopped and tr.mid != null and (local.getMedias()[tr.sdp_mline_index.?].port == 0 or
            remote.getMedias()[tr.sdp_mline_index.?].port == 0))
        {
            _ = pc.transceivers.orderedRemove(idx);
            continue;
        }

        idx += 1;
    }
}

fn startSenderReports(pc: *PeerConnection) !void {
    try pc.group.concurrent(pc.dtls_transport.getIo(), sendReports, .{pc});
}

fn sendReports(pc: *PeerConnection) !void {
    pc.doSendReports() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| Logger.err("Error occurred while sending report: {}", .{e}),
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

        const buffer = try pc.dtls_transport.ice_agent.createPacket();
        defer pc.dtls_transport.ice_agent.destroyPacket(buffer);
        const timestamp = Io.Timestamp.now(io, .real).toMicroseconds();

        for (0..pc.transceivers.items.len) |idx| {
            const tr = pc.transceivers.items[idx];
            if (tr.isStopped() or tr.direction == .inactive) continue;

            Logger.debug("send rtcp report for transceiver: {?s}", .{tr.mid});
            const data = tr.getRtcpReport(timestamp, buffer);
            if (data.len == 0) continue;
            try pc.dtls_transport.sendRtcp(data);
        }
    }
}

fn generateSsrc(io: Io, demuxer: *const Demuxer) !u32 {
    var max_retries: usize = 100;
    var buf: [4]u8 = @splat(0);
    while (max_retries > 0) : (max_retries -= 1) {
        io.random(&buf);
        const ssrc = std.mem.readInt(u32, &buf, .big);
        if (!demuxer.ssrc_to_mid.contains(ssrc)) return ssrc;
    }

    return error.SsrcUnavailable;
}

test {
    _ = @import("tests/peer_connection.zig");
    _ = @import("pc/demuxer.zig");
}
