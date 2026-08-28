const std = @import("std");

pub const Message = union(enum) {
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
        const message_type = r.takeByte() catch return error.ParseError;
        switch (message_type) {
            0x02 => {
                if (data.len != 1) return error.ParseError;
                return .ack;
            },
            0x03 => {
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
            else => return error.ParseError,
        }
    }
};

label: []const u8,
ordered: bool,

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
