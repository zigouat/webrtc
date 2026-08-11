const std = @import("std");
const rtp = @import("rtp");

const SendBuffer = @This();

const Entry = packed struct {
    payload_len: u15,
    available: bool,

    const empty: Entry = .{
        .payload_len = 0,
        .available = false,
    };

    fn from(len: usize) Entry {
        return .{
            .payload_len = @intCast(len),
            .available = true,
        };
    }
};

size: u16,
max_rtp_payload: u16,
buffer: []u8,
entries: []Entry,
highest_seq_number: u16,
started: bool,

pub fn init(allocator: std.mem.Allocator, size: u16, max_rtp_payload: u16) !SendBuffer {
    if (!std.math.isPowerOfTwo(size)) return error.InvalidSize;

    const buffer_size = @as(usize, size) * max_rtp_payload;
    const buffer = try allocator.alloc(u8, buffer_size);
    errdefer allocator.free(buffer);

    const entries = try allocator.alloc(Entry, size);
    @memset(entries, Entry.empty);

    return .{
        .size = size,
        .max_rtp_payload = max_rtp_payload,
        .buffer = buffer,
        .entries = entries,
        .highest_seq_number = 0,
        .started = false,
    };
}

pub fn deinit(send_buffer: *SendBuffer, allocator: std.mem.Allocator) void {
    allocator.free(send_buffer.buffer);
    allocator.free(send_buffer.entries);
}

pub fn add(send_buffer: *SendBuffer, packet: *const rtp.Packet) void {
    const index = packet.header.sequence_number & (send_buffer.size - 1);

    const offset = @as(usize, index) * send_buffer.max_rtp_payload;
    if (!send_buffer.started) {
        send_buffer.highest_seq_number = packet.header.sequence_number;
        send_buffer.started = true;
        @memcpy(send_buffer.buffer[offset .. offset + packet.payload.len], packet.payload);
        send_buffer.entries[index] = .from(packet.payload.len);
        return;
    }

    const diff = @as(i16, @bitCast(packet.header.sequence_number)) -% @as(i16, @bitCast(send_buffer.highest_seq_number));
    if (diff == 0) return;

    if (diff > 0) {
        var next = send_buffer.highest_seq_number +% 1;
        while (next != packet.header.sequence_number) : (next +%= 1) {
            send_buffer.entries[next & (send_buffer.size - 1)] = Entry.empty;
        }
        send_buffer.highest_seq_number = packet.header.sequence_number;
    }

    @memcpy(send_buffer.buffer[offset .. offset + packet.payload.len], packet.payload);
    send_buffer.entries[index] = .from(packet.payload.len);
}

pub fn get(send_buffer: *SendBuffer, seq_number: u16) ?[]u8 {
    const index = seq_number & (send_buffer.size - 1);
    const entry = send_buffer.entries[index];

    if (seq_number > send_buffer.highest_seq_number) return null;
    if (send_buffer.highest_seq_number - seq_number >= send_buffer.size) return null;
    if (!entry.available) return null;

    const offset = @as(usize, index) * send_buffer.max_rtp_payload;
    return send_buffer.buffer[offset .. offset + entry.payload_len];
}

const testing = std.testing;

fn testPacket(seq: u16, payload: []const u8) rtp.Packet {
    return .{
        .header = .{
            .ssrc = 1,
            .timestamp = 0,
            .sequence_number = seq,
            .payload_type = 96,
            .marker = false,
            .extension = false,
            .padding = false,
        },
        .payload = payload,
    };
}

test "init: rejects non power-of-two size" {
    try testing.expectError(error.InvalidSize, SendBuffer.init(testing.allocator, 3, 16));
}

test "add and get: roundtrips a single packet" {
    var send_buffer = try SendBuffer.init(testing.allocator, 4, 16);
    defer send_buffer.deinit(testing.allocator);

    send_buffer.add(&testPacket(0, "abc"));

    const got = send_buffer.get(0).?;
    try testing.expectEqualSlices(u8, "abc", got[0..3]);
}

test "get: returns null for a sequence number never added" {
    var send_buffer = try SendBuffer.init(testing.allocator, 4, 16);
    defer send_buffer.deinit(testing.allocator);

    send_buffer.add(&testPacket(0, "abc"));

    try testing.expectEqual(null, send_buffer.get(1));
}

test "get: returns null for a sequence number newer than the highest added" {
    var send_buffer = try SendBuffer.init(testing.allocator, 4, 16);
    defer send_buffer.deinit(testing.allocator);

    send_buffer.add(&testPacket(5, "abc"));

    try testing.expectEqual(null, send_buffer.get(6));
}

test "add: duplicate sequence number does not overwrite existing data" {
    var send_buffer = try SendBuffer.init(testing.allocator, 4, 16);
    defer send_buffer.deinit(testing.allocator);

    send_buffer.add(&testPacket(0, "abc"));
    send_buffer.add(&testPacket(0, "xyz"));

    const got = send_buffer.get(0).?;
    try testing.expectEqualSlices(u8, "abc", got[0..3]);
}

test "add: out-of-order packet is stored without advancing the highest sequence number" {
    var send_buffer = try SendBuffer.init(testing.allocator, 4, 16);
    defer send_buffer.deinit(testing.allocator);

    send_buffer.add(&testPacket(5, "second"));
    send_buffer.add(&testPacket(4, "first"));

    try testing.expectEqual(5, send_buffer.highest_seq_number);

    const got = send_buffer.get(4).?;
    try testing.expectEqualSlices(u8, "first", got[0..5]);
}

test "add: advancing past the window evicts old entries" {
    var send_buffer = try SendBuffer.init(testing.allocator, 4, 16);
    defer send_buffer.deinit(testing.allocator);

    send_buffer.add(&testPacket(0, "abc"));
    send_buffer.add(&testPacket(7, "xyz"));

    try testing.expectEqual(7, send_buffer.highest_seq_number);
    for (0..7) |seq| {
        try testing.expectEqual(null, send_buffer.get(@intCast(seq)));
    }
}

test "add: sequence number wraparound is treated as newer" {
    var send_buffer = try SendBuffer.init(testing.allocator, 4, 16);
    defer send_buffer.deinit(testing.allocator);

    send_buffer.add(&testPacket(65535, "abc"));
    send_buffer.add(&testPacket(1, "xyz"));

    try testing.expectEqual(1, send_buffer.highest_seq_number);

    const got = send_buffer.get(1).?;
    try testing.expectEqualSlices(u8, "xyz", got[0..3]);
}
