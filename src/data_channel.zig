const std = @import("std");
const SctpTransport = @import("sctp_transport.zig");

const DataChannel = @This();
const EventCallback = *const fn (userdata: ?*anyopaque, data_channel: *DataChannel, event: DataChannel.Event) void;

pub const State = enum { connecting, open, closing, closed };

pub const MessageType = enum(u8) {
    ack = 0x02,
    open = 0x03,
};

pub const Message = union(MessageType) {
    pub const ChannelType = enum(u8) {
        reliable = 0x00,
        reliable_unordered = 0x80,
        partial_reliable_rexmit = 0x01,
        partial_reliable_rexmit_unordered = 0x81,
        partial_reliable_timed = 0x02,
        partial_reliable_timed_unordered = 0x82,
    };

    ack: void,
    open: struct {
        channel_type: ChannelType,
        priority: u16,
        reliability_param: u32,
        label: []const u8,
        protocol: []const u8,
    },

    pub fn parse(data: []const u8) error{ParseError}!Message {
        var r = std.Io.Reader.fixed(data);
        const message_type = r.takeEnum(MessageType, .big) catch return error.ParseError;
        switch (message_type) {
            .ack => {
                if (data.len != 1) return error.ParseError;
                return .ack;
            },
            .open => {
                const channel_type = r.takeEnum(ChannelType, .big) catch return error.ParseError;
                const priority = r.takeInt(u16, .big) catch return error.ParseError;
                const reliability_param = r.takeInt(u32, .big) catch return error.ParseError;

                const label_length = r.takeInt(u16, .big) catch return error.ParseError;
                const protocol_length = r.takeInt(u16, .big) catch return error.ParseError;

                const label = r.take(label_length) catch return error.ParseError;
                const protocol = r.take(protocol_length) catch return error.ParseError;

                if (r.bufferedLen() != 0) return error.ParseError;

                return Message{
                    .open = .{
                        .channel_type = channel_type,
                        .priority = priority,
                        .reliability_param = reliability_param,
                        .label = label,
                        .protocol = protocol,
                    },
                };
            },
        }
    }

    pub fn toParameters(message: *const Message, stream_id: u16) Parameters {
        const open_msg = message.open;
        return DataChannel.Parameters{
            .protocol = open_msg.protocol,
            .ordered = switch (open_msg.channel_type) {
                .reliable, .partial_reliable_rexmit, .partial_reliable_timed => true,
                else => false,
            },
            .max_packet_lifetime = switch (open_msg.channel_type) {
                .partial_reliable_timed, .partial_reliable_timed_unordered => open_msg.reliability_param,
                else => 0,
            },
            .max_retransmits = switch (open_msg.channel_type) {
                .partial_reliable_rexmit, .partial_reliable_rexmit_unordered => open_msg.reliability_param,
                else => 0,
            },
            .id = stream_id,
        };
    }
};

pub const Parameters = struct {
    ordered: bool = true,
    max_packet_lifetime: u32 = 0,
    max_retransmits: u32 = 0,
    protocol: []const u8 = "",
    id: ?u16 = null,
};

pub const Event = union(enum) {
    open: void,
    close: void,
    err: void,
    text_message: []const u8,
    binary_message: []const u8,
};

id: ?u16,
label: []const u8,
ordered: bool,
max_packet_lifetime: u32,
max_retransmits: u32,
protocol: []const u8,
ready_state: State,
sctp_tranport: *SctpTransport,
userdata: ?*anyopaque,
on_event: ?EventCallback,

pub fn init(
    allocator: std.mem.Allocator,
    label: []const u8,
    sctp_transport: *SctpTransport,
    params: Parameters,
) std.mem.Allocator.Error!DataChannel {
    const slice = try allocator.alloc(u8, label.len + params.protocol.len);
    @memcpy(slice[0..label.len], label);
    @memcpy(slice[label.len..], params.protocol);

    return DataChannel{
        .id = params.id,
        .label = slice[0..label.len],
        .ordered = params.ordered,
        .max_packet_lifetime = params.max_packet_lifetime,
        .max_retransmits = params.max_retransmits,
        .protocol = slice[label.len..],
        .ready_state = State.connecting,
        .sctp_tranport = sctp_transport,
        .userdata = null,
        .on_event = null,
    };
}

pub fn deinit(data_channel: *DataChannel, allocator: std.mem.Allocator) void {
    const slice = data_channel.label.ptr;
    allocator.free(slice[0 .. data_channel.label.len + data_channel.protocol.len]);
}

pub fn writeOpenMessage(data_channel: *DataChannel, buffer: []u8) std.Io.Writer.Error![]const u8 {
    var w = std.Io.Writer.fixed(buffer);

    try w.writeInt(u8, @intFromEnum(MessageType.open), .big);
    const channel_type = data_channel.getChannelType();
    try w.writeInt(u8, @intFromEnum(channel_type), .big);
    try w.writeInt(u16, 0, .big); // priority
    try w.writeInt(u32, switch (channel_type) {
        .reliable, .reliable_unordered => 0,
        .partial_reliable_rexmit, .partial_reliable_rexmit_unordered => data_channel.max_retransmits,
        .partial_reliable_timed, .partial_reliable_timed_unordered => data_channel.max_packet_lifetime,
    }, .big);
    try w.writeInt(u16, @intCast(data_channel.label.len), .big);
    try w.writeInt(u16, @intCast(data_channel.protocol.len), .big);
    try w.writeAll(data_channel.label);
    try w.writeAll(data_channel.protocol);

    return w.buffered();
}

pub fn format(data_channel: *DataChannel, writer: *std.Io.Writer) !void {
    try writer.print("DataChannel {{ id: {?}, label: \"{s}\", ordered: {}, max_packet_lifetime: {}, max_retransmits: {}, protocol: \"{s}\", ready_state: {} }}", .{
        data_channel.id,
        data_channel.label,
        data_channel.ordered,
        data_channel.max_packet_lifetime,
        data_channel.max_retransmits,
        data_channel.protocol,
        data_channel.ready_state,
    });
}

pub fn setReadyState(data_channel: *DataChannel, state: State) void {
    data_channel.ready_state = state;
    if (data_channel.on_event) |on_event| switch (state) {
        .open => on_event(data_channel.userdata, data_channel, .open),
        .closed => on_event(data_channel.userdata, data_channel, .close),
        else => {},
    };
}

pub fn close(data_channel: *DataChannel) !void {
    if (data_channel.ready_state == .closing or data_channel.ready_state == .closed) return;

    const sid = data_channel.id orelse {
        data_channel.setReadyState(.closed);
        data_channel.sctp_tranport.deleteDataChannel(data_channel);
        return;
    };
    try data_channel.sctp_tranport.resetStreams(&.{sid}, .{ .outgoing = true });
    data_channel.setReadyState(.closing);
}

pub const SendError = error{ SendFailed, InvalidState };

pub fn sendText(data_channel: *DataChannel, data: []const u8) SendError!void {
    if (data.len == 0)
        try data_channel.send(&[_]u8{0}, SctpTransport.EMPTY_TEXT_MESSAGE_PPID)
    else
        try data_channel.send(data, SctpTransport.TEXT_MESSAGE_PPID);
}

pub fn sendBinary(data_channel: *DataChannel, data: []const u8) SendError!void {
    if (data.len == 0)
        try data_channel.send(&[_]u8{0}, SctpTransport.EMPTY_BINRAY_MESSAGE_PPID)
    else
        try data_channel.send(data, SctpTransport.BINARY_MESSAGE_PPID);
}

pub fn registerCallback(data_channel: *DataChannel, userdata: ?*anyopaque, callback: EventCallback) void {
    data_channel.userdata = userdata;
    data_channel.on_event = callback;
}

fn send(data_channel: *DataChannel, data: []const u8, ppid: u32) SendError!void {
    if (data_channel.ready_state != .open or data_channel.id == null) {
        @branchHint(.unlikely);
        return error.InvalidState;
    }

    try data_channel.sctp_tranport.socket.send(data, .{
        .ppid = ppid,
        .sid = data_channel.id.?,
        .ordered = data_channel.ordered,
        .max_retransmits = data_channel.max_retransmits,
        .max_lifetime = data_channel.max_packet_lifetime,
    });
}

fn getChannelType(data_channel: *DataChannel) Message.ChannelType {
    if (data_channel.ordered) {
        if (data_channel.max_packet_lifetime != 0) {
            return .partial_reliable_timed;
        } else if (data_channel.max_retransmits != 0) {
            return .partial_reliable_rexmit;
        } else {
            return .reliable;
        }
    } else {
        if (data_channel.max_packet_lifetime != 0) {
            return .partial_reliable_timed_unordered;
        } else if (data_channel.max_retransmits != 0) {
            return .partial_reliable_rexmit_unordered;
        } else {
            return .reliable_unordered;
        }
    }
}

const testing = std.testing;

test "DataChannel.Message.parse" {
    const data = [_]u8{
        0x03, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x64, 0x61, 0x74,
        0x61,
    };
    const msg = try Message.parse(&data);
    try testing.expect(msg == .open);

    const open_msg = msg.open;
    try testing.expectEqual(.reliable, open_msg.channel_type);
    try testing.expectEqual(0, open_msg.priority);
    try testing.expectEqual(0, open_msg.reliability_param);
    try testing.expectEqualStrings("data", open_msg.label);
    try testing.expectEqualStrings("", open_msg.protocol);
}

test "DataChannel.writeOpenMessage" {
    const expected = [_]u8{
        0x03, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x64, 0x61, 0x74,
        0x61,
    };
    var buffer: [1024]u8 = undefined;

    var data_channel = try init(testing.allocator, "data", undefined, .{
        .id = 0,
        .ordered = true,
    });
    defer data_channel.deinit(testing.allocator);

    const written = try data_channel.writeOpenMessage(&buffer);
    try testing.expectEqualSlices(u8, &expected, written);
}

test "DataChannel.close: no-op if already closing or closed" {
    var data_channel = try init(testing.allocator, "chan", undefined, .{});
    data_channel.setReadyState(.closed);
    defer data_channel.deinit(testing.allocator);

    try data_channel.close();
    try testing.expectEqual(.closed, data_channel.ready_state);
}
