const std = @import("std");

const SocketHandler = @This();
const Io = std.Io;

pub const ReturnAction = union(enum) {
    close: void,
    switch_cb: *const Callback,
    none: void,
};

const Callback = fn (?*anyopaque, socket: *Io.net.Socket, msg: Io.net.IncomingMessage) Io.Cancelable!ReturnAction;

const Slot = struct {
    socket: ?*Io.net.Socket,
    userdata: ?*anyopaque,
    cb: *const Callback,
    grp: Io.Group,
};

sockets: std.ArrayList(*Slot),

pub fn init() SocketHandler {
    return SocketHandler{ .sockets = .empty };
}

pub fn deinit(h: *SocketHandler, io: Io, allocator: std.mem.Allocator) void {
    for (h.sockets.items) |slot| {
        slot.grp.cancel(io);
        allocator.destroy(slot);
    }
    h.sockets.deinit(allocator);
}

pub fn registerSocket(
    h: *SocketHandler,
    io: Io,
    allocator: std.mem.Allocator,
    addr: *const Io.net.IpAddress,
    userdata: ?*anyopaque,
    cb: *const Callback,
) !?*Io.net.Socket {
    var created: Io.Event = .unset;

    const slot = try allocator.create(Slot);
    errdefer allocator.destroy(slot);

    slot.* = .{
        .grp = .init,
        .socket = null,
        .userdata = userdata,
        .cb = cb,
    };

    try h.sockets.append(allocator, slot);
    errdefer _ = h.sockets.pop();

    try slot.grp.concurrent(io, handleSocket, .{ io, slot, addr, &created });
    try created.wait(io);
    return slot.socket;
}

pub fn unregisterSocket(h: *SocketHandler, io: Io, socket: *Io.net.Socket) void {
    const idx = blk: {
        for (h.sockets.items, 0..) |slot, idx| {
            if (slot.socket == socket) {
                slot.grp.cancel(io);
                break :blk idx;
            }
        } else return;
    };

    _ = h.sockets.swapRemove(idx);
}

pub fn unregisterAllExcept(h: *SocketHandler, io: Io, allocator: std.mem.Allocator, except: *Io.net.Socket) void {
    var i: usize = 0;
    while (i < h.sockets.items.len) {
        const slot = h.sockets.items[i];
        if (slot.socket != except) {
            slot.grp.cancel(io);
            allocator.destroy(slot);
            _ = h.sockets.swapRemove(i);
            continue;
        }

        i += 1;
    }
}

pub fn findSocket(h: *SocketHandler, addr: *const Io.net.IpAddress) ?*Io.net.Socket {
    for (h.sockets.items) |slot| if (slot.socket) |socket| if (socket.address.eql(addr)) return socket;
    return null;
}

fn handleSocket(io: Io, slot: *Slot, addr: *const Io.net.IpAddress, created: *Io.Event) !void {
    var socket = addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch {
        created.set(io);
        return;
    };
    defer socket.close(io);

    slot.socket = &socket;
    created.set(io);

    var buffer: [1500]u8 = undefined;

    while (true) {
        const incoming_message = socket.receive(io, &buffer) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                std.log.err("Error while receiving data: {}", .{err});
                return;
            },
        };

        switch (try slot.cb(slot.userdata, &socket, incoming_message)) {
            .close => return,
            .switch_cb => |cb| slot.cb = cb,
            .none => {},
        }
    }
}
