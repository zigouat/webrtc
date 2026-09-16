const std = @import("std");

const TimerManager = @This();
const Io = std.Io;
const Queue = std.PriorityQueue(Entry, void, lessThan);
const Callback = *const fn (?*anyopaque, id: Id) void;

const Entry = struct {
    id: Id,
    deadline: i64,
    userdata: ?*anyopaque,
    cb: Callback,
};

fn lessThan(_: void, a: Entry, b: Entry) std.math.Order {
    return std.math.order(a.deadline, b.deadline);
}

pub const Id = u64;

queue: Queue = .empty,
mutex: Io.Mutex = .init,
wake: Io.Event = .unset,
next_id: Id = 0,

pub fn deinit(self: *TimerManager, allocator: std.mem.Allocator) void {
    self.queue.deinit(allocator);
}

pub fn schedule(
    self: *TimerManager,
    allocator: std.mem.Allocator,
    io: Io,
    deadline: i64,
    usedata: ?*anyopaque,
    cb: Callback,
) !Id {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const is_earliest = if (self.queue.peek()) |top| deadline < top.deadline else true;

    const id = self.next_id;
    self.next_id += 1;
    try self.queue.push(allocator, .{ .id = id, .deadline = deadline, .userdata = usedata, .cb = cb });

    if (is_earliest) self.wake.set(io);
    return id;
}

pub fn cancel(self: *TimerManager, io: Io, id: Id) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    for (self.queue.items, 0..) |entry, index| {
        if (entry.id != id) continue;
        _ = self.queue.popIndex(index);
        return;
    }
}

pub fn run(self: *TimerManager, io: Io) Io.Cancelable!void {
    while (true) {
        self.mutex.lockUncancelable(io);
        var now = Io.Timestamp.now(io, .awake).toMilliseconds();

        while (self.queue.peek()) |top| {
            if (top.deadline > now) break;
            const fired = self.queue.pop().?;
            self.mutex.unlock(io);
            fired.cb(fired.userdata, fired.id);
            self.mutex.lockUncancelable(io);
            now = Io.Timestamp.now(io, .awake).toMilliseconds();
        }
        const wait_ms: ?i64 = if (self.queue.peek()) |top| top.deadline - now else null;
        self.mutex.unlock(io);

        if (wait_ms) |ms| {
            self.wake.waitTimeout(io, .{
                .duration = .{ .raw = .fromMilliseconds(@max(ms, 0)), .clock = .awake },
            }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return error.Canceled,
            };
        } else {
            try self.wake.wait(io);
        }
        self.wake.reset();
    }
}
