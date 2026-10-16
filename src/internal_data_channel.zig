const std = @import("std");
const sctp = @import("sctp");

const InternalDataChannel = @This();

pub const ChannelId = u32;

pub const StreamResetFlag = struct {
    outgoing: bool = false,
    incoming: bool = false,
};

pub const State = enum { connecting, open, closing, closed };

pub const UserMessage = struct {
    channel_id: ChannelId,
    binary: bool,
    data: []const u8,
};

pub const Event = union(enum) {
    new: ChannelId,
    open: ChannelId,
    close: ChannelId,
};

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
        return InternalDataChannel.Parameters{
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

id: ?u16,
slice: []const u8, // label + protocol
label_length: u16,
ordered: bool,
max_packet_lifetime: u32,
max_retransmits: u32,
ready_state: State,

pub fn init(allocator: std.mem.Allocator, label: []const u8, params: Parameters) std.mem.Allocator.Error!InternalDataChannel {
    const slice = try allocator.alloc(u8, label.len + params.protocol.len);
    @memcpy(slice[0..label.len], label);
    @memcpy(slice[label.len..], params.protocol);

    return InternalDataChannel{
        .id = params.id,
        .slice = slice,
        .label_length = @intCast(label.len),
        .ordered = params.ordered,
        .max_packet_lifetime = params.max_packet_lifetime,
        .max_retransmits = params.max_retransmits,
        .ready_state = State.connecting,
    };
}

pub fn deinit(data_channel: *InternalDataChannel, allocator: std.mem.Allocator) void {
    allocator.free(data_channel.slice);
    data_channel.slice = &.{};
    data_channel.label_length = 0;
}

pub fn getLabel(data_channel: *const InternalDataChannel) []const u8 {
    return data_channel.slice[0..data_channel.label_length];
}

pub fn getProtocol(data_channel: *const InternalDataChannel) []const u8 {
    return data_channel.slice[data_channel.label_length..];
}

const DCEP_PPID: u32 = 50;
const TEXT_MESSAGE_PPID: u32 = 51;
const BINARY_MESSAGE_PPID: u32 = 53;
const EMPTY_TEXT_MESSAGE_PPID: u32 = 56;
const EMPTY_BINRAY_MESSAGE_PPID: u32 = 57;

pub fn writeOpenMessage(data_channel: *const InternalDataChannel, buffer: []u8) std.Io.Writer.Error!sctp.message.UserMessage {
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
    try w.writeInt(u16, data_channel.label_length, .big);
    try w.writeInt(u16, @intCast(data_channel.slice.len - data_channel.label_length), .big);
    try w.writeAll(data_channel.slice);

    return sctp.message.UserMessage{
        .data = w.buffered(),
        .ppid = DCEP_PPID,
        .stream_id = data_channel.id.?,
        .unordered = false,
        .stream_seq = 0,
    };
}

pub fn writeAckMessage(data_channel: *const InternalDataChannel) sctp.message.UserMessage {
    return sctp.message.UserMessage{
        .data = &[_]u8{@intFromEnum(MessageType.ack)},
        .ppid = DCEP_PPID,
        .stream_id = data_channel.id.?,
        .unordered = false,
        .stream_seq = 0,
    };
}

pub fn wrapMessage(dc: *const InternalDataChannel, data: []const u8, binary: bool) sctp.message.UserMessage {
    const ppid = if (binary and data.len == 0)
        EMPTY_BINRAY_MESSAGE_PPID
    else if (binary)
        BINARY_MESSAGE_PPID
    else if (data.len == 0)
        EMPTY_TEXT_MESSAGE_PPID
    else
        TEXT_MESSAGE_PPID;

    return sctp.message.UserMessage{
        .data = data,
        .ppid = ppid,
        .stream_id = dc.id.?,
        .unordered = !dc.ordered,
        .stream_seq = 0,
    };
}

pub fn format(data_channel: *const InternalDataChannel, writer: *std.Io.Writer) !void {
    try writer.print("DataChannel {{ id: {?d}, label: \"{s}\", ordered: {}, max_packet_lifetime: {d}, max_retransmits: {d}, protocol: \"{s}\", ready_state: {t} }}", .{
        data_channel.id,
        data_channel.getLabel(),
        data_channel.ordered,
        data_channel.max_packet_lifetime,
        data_channel.max_retransmits,
        data_channel.getProtocol(),
        data_channel.ready_state,
    });
}

fn getChannelType(data_channel: *const InternalDataChannel) Message.ChannelType {
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

test "InternalDataChannel.Message.parse" {
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

test "InternalDataChannel.writeOpenMessage" {
    const expected = [_]u8{
        0x03, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x64, 0x61, 0x74,
        0x61,
    };
    var buffer: [1024]u8 = undefined;

    var data_channel = try init(testing.allocator, "data", .{
        .id = 0,
        .ordered = true,
    });
    defer data_channel.deinit(testing.allocator);

    const written = try data_channel.writeOpenMessage(&buffer);
    try testing.expectEqualSlices(u8, &expected, written.data);
}

test "InternalDataChannel.Message.parse open with protocol and reliability" {
    const data = [_]u8{
        0x03, 0x81, 0x01, 0x00, 0x00, 0x00, 0x00, 0x05,
        0x00, 0x03, 0x00, 0x04, 'a',  'b',  'c',  'j',
        's',  'o',  'n',
    };
    const msg = try Message.parse(&data);
    try testing.expect(msg == .open);

    const open_msg = msg.open;
    try testing.expectEqual(.partial_reliable_rexmit_unordered, open_msg.channel_type);
    try testing.expectEqual(256, open_msg.priority);
    try testing.expectEqual(5, open_msg.reliability_param);
    try testing.expectEqualStrings("abc", open_msg.label);
    try testing.expectEqualStrings("json", open_msg.protocol);
}

test "InternalDataChannel.Message.parse ack" {
    const msg = try Message.parse(&.{0x02});
    try testing.expect(msg == .ack);
}

test "InternalDataChannel.Message.parse invalid" {
    const cases = [_][]const u8{
        &.{},
        &.{0x01},
        &.{ 0x02, 0x00 },
        &.{ 0x03, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        &.{ 0x03, 0x00, 0x00, 0x00, 0x00 },
        &.{ 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 'a' },
        &.{ 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 'a', 'b' },
    };

    for (cases) |data| try testing.expectError(error.ParseError, Message.parse(data));
}

test "InternalDataChannel.Message.toParameters" {
    const Case = struct { Message.ChannelType, Parameters };
    const cases = [_]Case{
        .{ .reliable, .{ .ordered = true, .id = 7 } },
        .{ .reliable_unordered, .{ .ordered = false, .id = 7 } },
        .{ .partial_reliable_rexmit, .{ .ordered = true, .max_retransmits = 9, .id = 7 } },
        .{ .partial_reliable_rexmit_unordered, .{ .ordered = false, .max_retransmits = 9, .id = 7 } },
        .{ .partial_reliable_timed, .{ .ordered = true, .max_packet_lifetime = 9, .id = 7 } },
        .{ .partial_reliable_timed_unordered, .{ .ordered = false, .max_packet_lifetime = 9, .id = 7 } },
    };

    for (cases) |case| {
        const channel_type, var expected = case;
        expected.protocol = "proto";
        const msg: Message = .{ .open = .{
            .channel_type = channel_type,
            .priority = 0,
            .reliability_param = 9,
            .label = "label",
            .protocol = "proto",
        } };
        try testing.expectEqualDeep(expected, msg.toParameters(7));
    }
}

test "InternalDataChannel.init" {
    var label = "chat".*;
    var data_channel = try init(testing.allocator, &label, .{
        .protocol = "json",
        .ordered = false,
        .max_retransmits = 3,
        .id = 4,
    });
    defer data_channel.deinit(testing.allocator);

    label[0] = 'x';

    try testing.expectEqualStrings("chat", data_channel.getLabel());
    try testing.expectEqualStrings("json", data_channel.getProtocol());
    try testing.expectEqual(4, data_channel.id);
    try testing.expectEqual(false, data_channel.ordered);
    try testing.expectEqual(3, data_channel.max_retransmits);
    try testing.expectEqual(0, data_channel.max_packet_lifetime);
    try testing.expectEqual(.connecting, data_channel.ready_state);
}

test "InternalDataChannel.writeOpenMessage round trip" {
    const cases = [_]Parameters{
        .{ .id = 1 },
        .{ .id = 2, .ordered = false },
        .{ .id = 3, .max_retransmits = 5, .protocol = "json" },
        .{ .id = 4, .ordered = false, .max_retransmits = 5 },
        .{ .id = 5, .max_packet_lifetime = 1000 },
        .{ .id = 6, .ordered = false, .max_packet_lifetime = 1000, .protocol = "p" },
    };
    var buffer: [1024]u8 = undefined;

    for (cases) |params| {
        var data_channel = try init(testing.allocator, "label", params);
        defer data_channel.deinit(testing.allocator);

        const written = try data_channel.writeOpenMessage(&buffer);
        try testing.expectEqual(DCEP_PPID, written.ppid);
        try testing.expectEqual(params.id.?, written.stream_id);
        try testing.expectEqual(false, written.unordered);

        const msg = try Message.parse(written.data);
        try testing.expectEqualStrings("label", msg.open.label);
        try testing.expectEqualDeep(params, msg.toParameters(params.id.?));
    }
}

test "InternalDataChannel.writeOpenMessage buffer too small" {
    var buffer: [8]u8 = undefined;
    var data_channel = try init(testing.allocator, "data", .{ .id = 0 });
    defer data_channel.deinit(testing.allocator);

    try testing.expectError(error.WriteFailed, data_channel.writeOpenMessage(&buffer));
}

test "InternalDataChannel.writeAckMessage" {
    var data_channel = try init(testing.allocator, "data", .{ .id = 3 });
    defer data_channel.deinit(testing.allocator);

    const ack = data_channel.writeAckMessage();
    try testing.expectEqualSlices(u8, &.{0x02}, ack.data);
    try testing.expectEqual(DCEP_PPID, ack.ppid);
    try testing.expectEqual(3, ack.stream_id);
    try testing.expectEqual(false, ack.unordered);
    try testing.expect(try Message.parse(ack.data) == .ack);
}

test "InternalDataChannel.wrapMessage" {
    var ordered = try init(testing.allocator, "data", .{ .id = 1 });
    defer ordered.deinit(testing.allocator);
    var unordered = try init(testing.allocator, "data", .{ .id = 2, .ordered = false });
    defer unordered.deinit(testing.allocator);

    const Case = struct { []const u8, bool, u32 };
    const cases = [_]Case{
        .{ "hello", false, TEXT_MESSAGE_PPID },
        .{ "", false, EMPTY_TEXT_MESSAGE_PPID },
        .{ "hello", true, BINARY_MESSAGE_PPID },
        .{ "", true, EMPTY_BINRAY_MESSAGE_PPID },
    };

    for (cases) |case| {
        const data, const binary, const ppid = case;

        const msg = ordered.wrapMessage(data, binary);
        try testing.expectEqual(ppid, msg.ppid);
        try testing.expectEqualSlices(u8, data, msg.data);
        try testing.expectEqual(1, msg.stream_id);
        try testing.expectEqual(false, msg.unordered);

        try testing.expectEqual(true, unordered.wrapMessage(data, binary).unordered);
    }
}

test "InternalDataChannel.format" {
    var data_channel = try init(testing.allocator, "chat", .{ .id = 2, .protocol = "json", .max_retransmits = 3 });
    defer data_channel.deinit(testing.allocator);

    var buffer: [256]u8 = undefined;
    const out = try std.fmt.bufPrint(&buffer, "{f}", .{&data_channel});
    try testing.expectEqualStrings(
        "DataChannel { id: 2, label: \"chat\", ordered: true, max_packet_lifetime: 0, max_retransmits: 3, protocol: \"json\", ready_state: connecting }",
        out,
    );
}
