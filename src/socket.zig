const std = @import("std");
const events = @import("events.zig");

const logger = std.log.scoped(.socket);
var allocator: std.mem.Allocator = undefined;
var listener: std.net.StreamServer = undefined;
const PollEnum = enum { Addr };
var watcher: std.io.Poller(PollEnum) = undefined;
var pid: std.Thread = undefined;
var quit = false;

pub fn init(alloc_pointer: std.mem.Allocator, port: u16) !void {
    quit = false;
    allocator = alloc_pointer;
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    listener = std.net.StreamServer.init(.{});
    try listener.listen(addr);
    pid = try std.Thread.spawn(.{}, loop, .{});
}

pub fn deinit() void {
    quit = true;
    // watcher.deinit();
    listener.close();
    pid.join();
    listener.deinit();
}

const ReceiveError = error{
    EOF,
    BufferExceeded,
};

pub fn loop() !void {
    pid.setName("socket_thread") catch {};
    // watcher = std.io.poll(allocator, PollEnum, .{ .Addr = listener.sockfd.? });
    while (!quit) {
        // const data = try watcher.poll();
        // if (!data) continue;
        const connection = listener.accept() catch |err| {
            logger.err("connection error: {}", .{err});
            continue;
        };
        logger.info("new connection: {}", .{connection.address.in.getPort()});
        defer connection.stream.close();
        var stream_reader = connection.stream.reader();
        const line = try stream_reader.readAllAlloc(allocator, 1000);
        defer allocator.free(line);
        const linez = allocator.dupeZ(u8, line) catch @panic("OOM!");
        const event = .{
            .Exec_Code_Line = .{
                .line = linez,
            },
        };
        events.post(event);
    }
}
