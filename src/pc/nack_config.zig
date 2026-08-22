//! Defines the configuration for the NACK support.
//!
//! All the configuration options apply only when a negotiated codec advertises nack feedback.

/// The size of the buffer used to store packets for retransmission.
send_buffer_size: u16 = 1024,
/// The size of the buffer used to check for missing packets and generate nack feedback.
receive_log_size: u16 = 512,
/// The interval in milliseconds to check for missing packets and generate nack feedback.
interval: u16 = 100,
