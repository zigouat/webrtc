const std = @import("std");
const ice = @import("ice");
const rtp = @import("rtp");
const rtcp = @import("rtcp");
const srtp = @import("srtp");
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

pub const Error = error{InvalidState} || std.mem.Allocator.Error;

pub const Event = union(enum) {
    connection_state: webrtc.ConnectionState,
    rtp: rtp.Packet,
    rtcp: []const u8,
};

allocator: std.mem.Allocator,
signaling_state: webrtc.SignalingState,
connection_state: webrtc.ConnectionState,

local_description: ?ParsedSesssionDescription = null,
remote_description: ?ParsedSesssionDescription = null,
pending_local_description: ?ParsedSesssionDescription = null,
pending_remote_description: ?ParsedSesssionDescription = null,
last_offer: ParsedSesssionDescription = .empty(.offer),
last_answer: ParsedSesssionDescription = .empty(.answer),

transceivers: std.ArrayList(webrtc.RtpTransceiver) = .empty,
dtls_transport: DtlsTransport,
demuxer: Demuxer,

/// Used as a counter for generating mid values for transceivers.
mid: u16 = 0,

queue_buffer: []Event,
queue: Io.Queue(Event),
group: std.Io.Group = .init,

pub const Config = struct {};

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
            .desc_type = sess_desc.desc_type,
            .sdp = sess_desc.sdp,
        };
    }
};

pub fn init(io: Io, allocator: std.mem.Allocator, config: Config) !PeerConnection {
    _ = config;

    var dtls_transport: DtlsTransport = try .init(io, allocator, .{
        .certificate = webrtc.certificate,
        .private_key = webrtc.private_key,
    });
    errdefer dtls_transport.deinit();

    const queue_buffer = try allocator.alloc(Event, 5);

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

    for (pc.transceivers.items) |*tr| tr.deinit(pc.allocator);
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

pub fn addTrack(pc: *PeerConnection, track: webrtc.MediaStreamTrack) Error!void {
    try pc.checkNotClosed();

    const transceiver = blk: {
        for (pc.transceivers.items) |*tr| if (tr.canAssociateTrack(track.kind)) {
            tr.setSenderTrack(track);
            break :blk tr;
        };

        break :blk null;
    };

    if (transceiver == null) try pc.transceivers.append(pc.allocator, .initFromTrack(track, &pc.dtls_transport));
}

pub fn addTransceiverFromTrack(track: webrtc.MediaStreamTrack) Error!void {
    _ = track;
    @compileError("Not implemented");
}

/// Creates a new offer.
///
/// Pointers are invalidated in the next call to `createOffer`.
pub fn createOffer(pc: *PeerConnection) !webrtc.SessionDescription {
    try pc.checkNotClosed();

    var w = std.Io.Writer.Allocating.init(pc.allocator);
    errdefer w.deinit();

    var sdp_session: SDPSession = .empty;
    pc.dtls_transport.session.getFingerprint(&sdp_session.fingerprint);

    const transceivers = pc.transceivers.items;

    const count_medias = blk: {
        var count: usize = 0;
        for (transceivers) |*tr| if (tr.current_direction != .stopped or tr.mid != null) {
            count += 1;
        };
        break :blk count;
    };

    var mline_idx: u8 = 0;
    const medias = try pc.allocator.alloc(SDPSession.SDPMedia, count_medias);
    errdefer {
        for (0..mline_idx) |idx| medias[idx].deinit(pc.allocator);
        pc.allocator.free(medias);
    }

    for (transceivers) |*tr| {
        if (tr.current_direction == .stopped and tr.mid == null) continue;
        medias[mline_idx] = try tr.toSdpMedia(pc.allocator);
        if (tr.mid == null) _ = try std.fmt.bufPrint(&medias[mline_idx].mid, "{}", .{pc.mid});

        tr.sdp_mline_index = mline_idx;
        mline_idx += 1;
        if (tr.mid == null) pc.mid +%= 1;
    }

    sdp_session.medias = medias;
    try sdp_session.write(&w.writer);

    pc.last_offer.deinit(pc.allocator);
    pc.last_offer = .{
        .desc_type = .offer,
        .sdp = try w.toOwnedSlice(),
        .session = sdp_session,
    };

    return pc.last_offer.toSessionDescription();
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
    pc.dtls_transport.session.getFingerprint(&sdp_session.fingerprint);

    var idx: usize = 0;
    const medias = try pc.allocator.alloc(SDPSession.SDPMedia, offer.session.medias.len);
    errdefer {
        for (0..idx) |id| medias[id].deinit(pc.allocator);
        pc.allocator.free(medias);
    }

    for (offer.session.medias) |*media| {
        const tr = pc.findTransceiverByMediaIndex(idx) orelse return error.Unexpected;
        const codecs = try utils.getCodecIntersection(pc.allocator, webrtc.getCodecCapabilities(tr.kind), media.rtp_codec_parameters);

        medias[idx] = .empty;
        medias[idx].kind = tr.kind;
        medias[idx].port = if (codecs.len == 0) 0 else media.port;
        medias[idx].rtcp_mux = true;
        medias[idx].rtcp_rsize = false;
        medias[idx].setup = .active;
        medias[idx].direction = media.direction.reverse().intersect(tr.direction);
        medias[idx].rtp_codec_parameters = if (codecs.len == 0)
            try pc.allocator.dupe(webrtc.RtpCodecParameters, media.rtp_codec_parameters)
        else
            codecs;

        @memcpy(medias[idx].mid[0..tr.mid.?.len], tr.mid.?);
        medias[idx].setIceCredentials(pc.dtls_transport.ice_agent.credentials);

        idx += 1;
    }

    sdp_session.medias = medias;
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

        return .{ .desc_type = desc.desc_type, .sdp = try w.toOwnedSlice() };
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

    switch (session_desc.desc_type) {
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

    switch (session_desc.desc_type) {
        .offer => switch (pc.signaling_state) {
            .have_remote_offer, .stable => try pc.applyRemoteDescription(session_desc),
            else => return error.InvalidState,
        },
        .answer => switch (pc.signaling_state) {
            .have_local_offer => try pc.applyRemoteDescription(session_desc),
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
    for (offer.medias, 0..) |*media, idx| {
        const transceiver = pc.findTransceiverByMediaIndex(idx).?;
        transceiver.mid = &media.mid;
    }

    if (pc.dtls_transport.ice_agent.gathering_state == .new) {
        try pc.group.concurrent(pc.dtls_transport.getIo(), pollTransportWrapper, .{pc});
        try pc.dtls_transport.gatherCandidates(getIceRole(.offer, false));
    }

    if (pc.pending_local_description) |*desc| desc.deinit(pc.allocator);
    pc.signaling_state = .have_local_offer;
    pc.pending_local_description = pc.last_offer;
    pc.last_offer = .empty(.offer);
}

fn applyLocalAnswer(pc: *PeerConnection, sess_desc: *const webrtc.SessionDescription) !void {
    if (!std.mem.eql(u8, pc.last_answer.sdp, sess_desc.sdp)) return error.TamperedOffer;
    const sdp_session = pc.last_answer.session;
    const offer_session = pc.pending_remote_description.?.session;

    var media_exists: bool = false;
    for (sdp_session.medias, 0..) |*media, idx| {
        const tr = pc.findTransceiverByMid(&media.mid).?;
        if (media.port == 0) {
            tr.stop();
            continue;
        }

        media_exists = true;

        const codecs = try utils.intersectCodecs(media.rtp_codec_parameters, offer_session.medias[idx].rtp_codec_parameters);
        tr.current_direction = media.direction;
        tr.sender.codecs = codecs.@"0";
        tr.receiver.codecs = codecs.@"1";
    }

    // if there's no negotiated media, don't start connectivity checks
    if (media_exists and pc.dtls_transport.ice_agent.gathering_state == .new) {
        try pc.group.concurrent(pc.dtls_transport.getIo(), pollTransportWrapper, .{pc});
        try pc.dtls_transport.gatherCandidates(getIceRole(.answer, sdp_session.ice_lite));
    }
    try pc.demuxer.updateMaps(&sdp_session);

    pc.pending_local_description = pc.last_answer;
    pc.updateSignalingStateToStable();
    pc.deleteTransceivers();
}

fn applyRemoteDescription(pc: *PeerConnection, session_desc: webrtc.SessionDescription) !void {
    const sdp_text = try pc.allocator.dupe(u8, session_desc.sdp);
    errdefer pc.allocator.free(sdp_text);

    var remote_sdp = try SDPSession.parse(pc.allocator, sdp_text);
    errdefer remote_sdp.deinit(pc.allocator);

    if (session_desc.desc_type == .answer) {
        const local_session = pc.pending_local_description.?.session;
        if (remote_sdp.medias.len != local_session.medias.len) return error.InvalidAnswer;
    }

    // TODO: validate rtp header extensions and add them to transceivers
    // TODO: Add ssrc to demuxer
    // TODO: Add rtcp feedback

    var first_media: ?*SDPSession.SDPMedia = null;
    for (remote_sdp.medias, 0..) |*media, idx| {
        var transceiver = blk: {
            switch (session_desc.desc_type) {
                .answer => {
                    const tr = pc.findTransceiverByMediaIndex(idx) orelse return error.NotExistingTransceiver;
                    break :blk tr;
                },
                .offer => {
                    for (pc.transceivers.items) |*tr| if (tr.canAssociateMedia(media)) break :blk tr;
                    const entry = try pc.transceivers.addOne(pc.allocator);
                    entry.* = .initFromSdpMedia(media, @intCast(idx));
                    entry.transport = &pc.dtls_transport;
                    break :blk entry;
                },
                else => unreachable,
            }
        };

        transceiver.mid = &media.mid;
        transceiver.sdp_mline_index = @intCast(idx);

        if (media.port == 0) {
            transceiver.stop();
            continue;
        }

        first_media = first_media orelse media;

        const direction = media.direction.reverse();
        switch (direction) {
            .recvonly, .sendrecv => {}, // TODO: get msids from sdp and associate with receiver track
            else => {},
        }
        transceiver.current_direction = direction;

        if (session_desc.desc_type == .answer) {
            const local_sdp = pc.pending_local_description.?.session;
            const local_codecs = local_sdp.medias[idx].rtp_codec_parameters;
            const remote_codecs = media.rtp_codec_parameters;
            const codecs = try utils.intersectCodecs(remote_codecs, local_codecs);

            transceiver.sender.codecs = codecs.@"0";
            transceiver.receiver.codecs = codecs.@"1";
        }
    }

    if (first_media) |media| {
        try pc.dtls_transport.applyIceAttributes(media);
        pc.dtls_transport.setPeerFingerprint(&remote_sdp.fingerprint);
    }

    switch (session_desc.desc_type) {
        .answer => {
            try pc.demuxer.updateMaps(&remote_sdp);
            pc.pending_remote_description = .{
                .desc_type = .answer,
                .sdp = sdp_text,
                .session = remote_sdp,
            };
            pc.updateSignalingStateToStable();
            pc.deleteTransceivers();
        },
        .offer => {
            pc.pending_remote_description = .{
                .desc_type = .offer,
                .sdp = sdp_text,
                .session = remote_sdp,
            };
            pc.signaling_state = .have_remote_offer;
        },
        else => {},
    }
}

fn updateSignalingStateToStable(pc: *PeerConnection) void {
    pc.signaling_state = .stable;

    if (pc.local_description) |*local_desc| local_desc.deinit(pc.allocator);
    if (pc.remote_description) |*remote_desc| remote_desc.deinit(pc.allocator);

    pc.local_description = pc.pending_local_description;
    pc.remote_description = pc.pending_remote_description;

    pc.pending_local_description = null;
    pc.pending_remote_description = null;

    pc.last_answer = .empty(.answer);
    pc.last_offer = .empty(.offer);
}

fn findTransceiverByMediaIndex(pc: *PeerConnection, index: usize) ?*webrtc.RtpTransceiver {
    for (pc.transceivers.items) |*transceiver| if (transceiver.sdp_mline_index) |tr_index| if (tr_index == index)
        return transceiver;

    return null;
}

fn findTransceiverByMid(pc: *PeerConnection, mid: []const u8) ?*webrtc.RtpTransceiver {
    for (pc.transceivers.items) |*transceiver| if (transceiver.mid) |tr_mid| if (std.mem.eql(u8, tr_mid, mid))
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
            if (pc.connection_state == .closed) return;
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

fn getIceRole(sess_type: webrtc.SessionDescriptionType, remote_ice_lite: bool) ice.Role {
    if (sess_type == .offer or remote_ice_lite) return .controlling;
    return .controlled;
}

fn deleteTransceivers(pc: *PeerConnection) void {
    if (pc.local_description == null or pc.remote_description == null) return;
    const local = pc.local_description.?.session;
    const remote = pc.remote_description.?.session;

    var idx: usize = 0;
    while (idx < pc.transceivers.items.len) {
        const tr = &pc.transceivers.items[idx];
        if (tr.direction == .stopped and tr.mid != null and (local.medias[tr.sdp_mline_index.?].port == 0 or
            remote.medias[tr.sdp_mline_index.?].port == 0))
        {
            _ = pc.transceivers.orderedRemove(idx);
            continue;
        }

        idx += 1;
    }
}

test {
    _ = @import("tests/peer_connection.zig");
    _ = @import("pc/demuxer.zig");
}
