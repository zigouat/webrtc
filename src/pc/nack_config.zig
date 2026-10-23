//! Defines the configuration for the NACK support.
//!
//! All the configuration options apply only when a negotiated codec advertises nack feedback.

/// The size of the buffer used to store packets for retransmission.
send_buffer_size: u16 = 1024,
/// The size of the buffer used to check for missing packets and generate nack feedback.
receive_log_size: u16 = 512,
/// The interval in milliseconds to check for missing packets and generate nack feedback.
interval: u16 = 100,

const std = @import("std");
const NackConfig = @This();

pub const Error = error{InvalidSendBufferSize};

/// `send_buffer_size` must be a power of two.
pub fn validate(config: NackConfig) Error!void {
    const size = config.send_buffer_size;
    if (size == 0 or !std.math.isPowerOfTwo(size)) return error.InvalidSendBufferSize;
}

test "NackConfig.validate" {
    try (NackConfig{}).validate();
    try std.testing.expectError(error.InvalidSendBufferSize, (NackConfig{ .send_buffer_size = 1000 }).validate());
    try std.testing.expectError(error.InvalidSendBufferSize, (NackConfig{ .send_buffer_size = 0 }).validate());
}
