# data-channels-flow-control
This example demonstrates how to use the following property / methods of `DataChannel`.

* pub fn bufferedAmount() u32
* pub fn setBufferedAmountLowThreshold(u32)
* pub fn getBufferedAmountLowThreshold()
* `buffered_amount_low_threshold: ChannelId` event

## When do we need it?
Send or SendText methods are called on DataChannel to send data to the connected peer.
The methods return immediately, but it does not mean the data was actually sent onto
the wire. Instead, it is queued in a buffer until it actually gets sent out to the wire.

When you have a large amount of data to send, it is an application's responsibility to
control the buffered amount in order not to indefinitely grow the buffer size to eventually
exhaust the memory.

The rate you wish to send data might be much higher than the rate the data channel can
actually send to the peer over the Internet. The above properties/methods help your
application to pace the amount of data to be pushed into the data channel.

## How to run
Clone the repository, cd into the `examples` folder and run:

```bash
zig build run-data_channels_flow_control
```
