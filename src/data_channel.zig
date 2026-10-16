const PeerConnection = @import("peer_connection.zig");
const InternalDataChannel = @import("internal_data_channel.zig");

const DataChannel = @This();

pub const ChannelId = InternalDataChannel.ChannelId;
pub const Parameters = InternalDataChannel.Parameters;
pub const State = InternalDataChannel.State;
pub const Event = InternalDataChannel.Event;
pub const UserMessage = InternalDataChannel.UserMessage;

id: ChannelId,
pc: *PeerConnection,

pub fn send(dc: DataChannel, data: []const u8) !void {
    return dc.pc.sendDataChannelMessage(dc.id, data);
}

pub fn close(dc: DataChannel) !void {
    return dc.pc.closeDataChannel(dc.id);
}

pub fn getLabel(dc: DataChannel) []const u8 {
    return dc.internal().getLabel();
}

pub fn getProtocol(dc: DataChannel) []const u8 {
    return dc.internal().getProtocol();
}

fn internal(dc: DataChannel) *InternalDataChannel {
    return &dc.pc.data_channels.items[dc.id];
}
