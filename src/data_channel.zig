const std = @import("std");
const PeerConnection = @import("peer_connection.zig");
const InternalDataChannel = @import("internal_data_channel.zig");

const DataChannel = @This();

pub const ChannelId = InternalDataChannel.ChannelId;
pub const Parameters = InternalDataChannel.Parameters;
pub const State = InternalDataChannel.State;
pub const Event = InternalDataChannel.Event;
pub const UserMessage = InternalDataChannel.UserMessage;

pub const CreateError = PeerConnection.ClosedError || error{
    LabelTooLong,
    ProtocolTooLong,
    InvalidParameters,
    NoAvailableStreamId,
} || std.mem.Allocator.Error;

pub const SendError = error{
    DataChannelNotOpen,
    MessageTooLarge,
} || std.mem.Allocator.Error || PeerConnection.ClosedError;

id: ChannelId,
pc: *PeerConnection,

pub fn send(dc: DataChannel, data: []const u8) SendError!void {
    return dc.pc.sendDataChannelMessage(dc.id, data, true);
}

pub fn sendText(dc: DataChannel, text: []const u8) SendError!void {
    return dc.pc.sendDataChannelMessage(dc.id, text, false);
}

pub fn close(dc: DataChannel) std.mem.Allocator.Error!void {
    return dc.pc.closeDataChannel(dc.id);
}

pub fn getLabel(dc: DataChannel) []const u8 {
    return dc.internal().getLabel();
}

pub fn getProtocol(dc: DataChannel) []const u8 {
    return dc.internal().getProtocol();
}

pub fn connect(dc: DataChannel, buffer: []u8) std.mem.Allocator.Error!void {
    const open_msg = dc.internal().writeOpenMessage(buffer) catch unreachable;
    dc.pc.sctp_transport.handleWrite(open_msg) catch |err| switch (err) {
        error.AssocNotConnected => unreachable,
        else => |e| return e,
    };
}

pub fn bufferedAmount(dc: DataChannel) u32 {
    const sid = dc.internal().id orelse return 0;
    return dc.pc.sctp_transport.bufferedAmount(sid);
}

pub fn getBufferedAmountLowThreshold(dc: DataChannel) u32 {
    return dc.internal().buffered_amount_low_threshold;
}

pub fn setBufferedAmountLowThreshold(dc: DataChannel, threshold: u32) error{OutOfMemory}!void {
    const internal_dc = dc.internal();
    if (internal_dc.id) |sid| try dc.pc.sctp_transport.setDataChannelBufferedAmountLowThreshold(sid, threshold);
    internal_dc.buffered_amount_low_threshold = threshold;
}

fn internal(dc: DataChannel) *InternalDataChannel {
    return &dc.pc.data_channels.items[dc.id];
}
