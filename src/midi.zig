const std = @import("std");
const c = @cImport({
    @cInclude("rtmidi/rtmidi_c.h");
});
const events = @import("events.zig");

var allocator: std.mem.Allocator = undefined;
var thread: std.Thread = undefined;
var quit = false;
var devices: []Device = undefined;
var midi_in: *c.RtMidiWrapper = undefined;
var midi_out: *c.RtMidiWrapper = undefined;
const logger = std.log.scoped(.midi);

const RtMidiPrefix = "seamstress";

pub const Dev_t = enum { Input, Output };
pub const Device = struct {
    id: u8,
    connected: bool = false,
    ptr: ?*c.RtMidiWrapper = null,
    name: ?[:0]const u8 = null,
    guts: Guts = .{ .Output = .{} },

    pub const Guts = union(Dev_t) {
        Input: input,
        Output: output,

        const input = struct {
            thread: ?std.Thread = null,
            buf: [1024]u8 = undefined,
            fn read(self: *Device) !void {
                var ptr = self.ptr orelse return error.Fail;
                var len: usize = 1024;
                while (len > 0) {
                    len = 1024;
                    const timestamp = c.rtmidi_in_get_message(ptr, &self.guts.Input.buf, &len);
                    if (!ptr.*.ok) {
                        const err = std.mem.span(ptr.*.msg);
                        logger.err("error in device {s}: {s}", .{ self.name.?, err });
                        self.connected = false;
                        return;
                    }
                    if (len == 0) break;
                    var line = try allocator.alloc(u8, len);
                    std.mem.copyForwards(u8, line, self.guts.Input.buf[0..len]);
                    const event = .{
                        .MIDI = .{
                            .message = line,
                            .timestamp = timestamp,
                            .id = self.id,
                        },
                    };
                    events.post(event);
                }
            }
            fn loop(self: *Device) !void {
                while (self.connected) {
                    try Device.Guts.input.read(self);
                    std.time.sleep(std.time.ns_per_us * 300);
                }
            }
        };
        pub const output = struct {
            pub fn write(self: *Device, message: []const u8) void {
                _ = c.rtmidi_out_send_message(self.ptr.?, message.ptr, @intCast(c_int, message.len));
                if (!self.ptr.?.*.ok) {
                    const err = std.mem.span(self.ptr.?.*.msg);
                    logger.err("error in device {s}: {s}", .{ self.name.?, err });
                    self.connected = false;
                }
            }
        };
    };
};

fn remove(id: usize) void {
    devices[id].connected = false;
    switch (devices[id].guts) {
        .Input => {
            if (devices[id].guts.Input.thread) |pid| pid.join();
            devices[id].guts.Input.thread = null;
            const event = .{
                .MIDI_Remove = .{ .id = devices[id].id, .dev_type = .Input },
            };
            events.post(event);
            if (devices[id].ptr) |p| {
                c.rtmidi_close_port(p);
                c.rtmidi_in_free(p);
            }
            devices[id].ptr = null;
        },
        .Output => {
            const event = .{
                .MIDI_Remove = .{ .id = devices[id].id, .dev_type = .Output },
            };
            events.post(event);
            if (devices[id].ptr) |p| {
                c.rtmidi_close_port(p);
                c.rtmidi_out_free(p);
            }
            devices[id].ptr = null;
        },
    }
}

pub fn init(alloc_pointer: std.mem.Allocator) !void {
    allocator = alloc_pointer;
    devices = try allocator.alloc(Device, 32);
    var idx: usize = 0;
    while (idx < 32) : (idx += 1) {
        devices[idx] = .{ .id = @intCast(u8, idx) };
    }
    thread = try std.Thread.spawn(.{}, main_loop, .{});
}

// NB: on Linux, RtMidi keeps on reanouncing registered devices w/ the added `RtMidiPrefix`
// this function allows retecting if a device name has this prefix (and thus is already registered)
fn is_prefixed(src: []const u8) bool {
    const prefix = RtMidiPrefix ++ ":";
    if (src.len > prefix.len and std.mem.eql(u8, prefix, src[0..prefix.len])) {
        return true;
    }
    return false;
}

fn main_loop() !void {
    midi_in = c.rtmidi_in_create(
        c.RTMIDI_API_UNSPECIFIED,
        RtMidiPrefix,
        1024,
    ) orelse return error.Fail;
    var in_name: [:0]const u8 = try std.fmt.allocPrintZ(allocator, "{s}", .{"seamstress_in"});
    c.rtmidi_open_virtual_port(midi_in, "seamstress_in");
    devices[0].connected = true;
    devices[0].ptr = midi_in;
    devices[0].name = in_name;
    devices[0].guts = .{ .Input = .{} };
    devices[0].guts.Input.thread = try std.Thread.spawn(.{}, Device.Guts.input.loop, .{&devices[0]});
    const event_once = .{
        .MIDI_Add = .{ .dev = &devices[0] },
    };
    events.post(event_once);

    midi_out = c.rtmidi_out_create(
        c.RTMIDI_API_UNSPECIFIED,
        RtMidiPrefix,
    ) orelse return error.Fail;
    var out_name: [:0]const u8 = try std.fmt.allocPrintZ(allocator, "{s}", .{"seamstress_out"});
    c.rtmidi_open_virtual_port(midi_out, "seamstress_out");
    devices[1].connected = true;
    devices[1].ptr = midi_out;
    devices[1].name = out_name;
    devices[1].guts = .{ .Output = .{} };
    const event_again = .{
        .MIDI_Add = .{ .dev = &devices[1] },
    };
    events.post(event_again);

    while (!quit) {
        var is_active: [32]bool = undefined;
        var i: c_uint = 0;
        while (i < 32) : (i += 1) is_active[i] = false;

        const in_count = c.rtmidi_get_port_count(midi_in);
        i = 0;
        while (i < in_count) : (i += 1) {
            var len: c_int = 256;
            _ = c.rtmidi_get_port_name(midi_in, i, null, &len);
            const usize_len = @intCast(usize, len);
            var buf = try allocator.allocSentinel(u8, usize_len, 0);
            defer allocator.free(buf);
            _ = c.rtmidi_get_port_name(midi_in, i, buf.ptr, &len);
            const spanned = std.mem.span(buf.ptr);
            if (find(.Input, spanned)) |id| {
                is_active[id] = true;
            } else {
                if (try add(.Input, i, spanned)) |id| is_active[id] = true;
            }
        }

        const out_count = c.rtmidi_get_port_count(midi_out);
        i = 0;
        while (i < out_count) : (i += 1) {
            var len: c_int = 256;
            _ = c.rtmidi_get_port_name(midi_out, i, null, &len);
            const usize_len = @intCast(usize, len);
            var buf = try allocator.allocSentinel(u8, usize_len, 0);
            defer allocator.free(buf);
            _ = c.rtmidi_get_port_name(midi_out, i, buf.ptr, &len);
            const spanned = std.mem.span(buf.ptr);
            if (!is_prefixed(spanned)) {
                if (find(.Output, spanned)) |id| {
                    is_active[id] = true;
                } else {
                    if (try add(.Output, i, spanned)) |id| is_active[id] = true;
                }
            }
        }
        i = 0;
        while (i < 32) : (i += 1) {
            if (devices[i].connected == is_active[i]) continue;
            if (!devices[i].connected and is_active[i]) {
                devices[i].connected = true;
                const event = .{
                    .MIDI_Add = .{ .dev = &devices[i] },
                };
                events.post(event);
                switch (devices[i].guts) {
                    .Output => {},
                    .Input => |*g| g.thread = try std.Thread.spawn(.{}, Device.Guts.input.loop, .{&devices[i]}),
                }
            }
            if (devices[i].connected and !is_active[i]) remove(i);
        }
        std.time.sleep(std.time.ns_per_s);
    }
}

fn find(dev_type: Dev_t, name: [:0]const u8) ?usize {
    // need a special case for ourselves.
    if (dev_type == .Input and std.mem.eql(u8, name, "seamstress_out")) return 1;
    if (dev_type == .Input and std.mem.eql(u8, name, "seamstress:seamstress_out")) return 1;
    if (dev_type == .Output and std.mem.eql(u8, name, "seamstress_in")) return 0;
    if (dev_type == .Output and std.mem.eql(u8, name, "seamstress:seamstress_in")) return 0;
    var i: usize = 2;
    while (i < 32) : (i += 1) {
        switch (devices[i].guts) {
            .Input => {
                if (dev_type != .Input) continue;
                const n = devices[i].name orelse continue;
                if (std.mem.eql(u8, name, n)) return i;
                const prefixed_name = std.fmt.allocPrint(allocator, "seamstress:{s}", .{n}) catch continue;
                if (std.mem.eql(u8, name, prefixed_name)) return i;
                defer allocator.free(prefixed_name);
            },
            .Output => {
                if (dev_type != .Output) continue;
                const n = devices[i].name orelse continue;
                if (std.mem.eql(u8, name, n)) return i;
                const prefixed_name = std.fmt.allocPrint(allocator, "seamstress:{s}", .{n}) catch continue;
                if (std.mem.eql(u8, name, prefixed_name)) return i;
                defer allocator.free(prefixed_name);
            },
        }
    }
    return null;
}

fn add(dev_type: Dev_t, port_number: c_uint, name: [:0]const u8) !?u8 {
    var free: ?*Device = null;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const is_free = devices[i].connected == false and devices[i].name == null;
        if (is_free) {
            free = &devices[i];
            break;
        }
    }
    var device = free orelse {
        @setCold(true);
        logger.err("too many devices! not adding {s}", .{name});
        return null;
    };
    switch (dev_type) {
        .Input => {
            const ptr = c.rtmidi_in_create(
                c.RTMIDI_API_UNSPECIFIED,
                RtMidiPrefix,
                1024,
            ) orelse return error.Fail;
            var c_name = try allocator.allocSentinel(u8, name.len, 0);
            std.mem.copyForwards(u8, c_name, name);
            c.rtmidi_open_port(ptr, port_number, c_name.ptr);
            const id = device.id;
            device.ptr = ptr;
            device.name = c_name;
            device.guts = .{ .Input = .{} };
            return id;
        },
        .Output => {
            const ptr = c.rtmidi_out_create(
                c.RTMIDI_API_UNSPECIFIED,
                RtMidiPrefix,
            ) orelse return error.Fail;
            var c_name = try allocator.allocSentinel(u8, name.len, 0);
            std.mem.copyForwards(u8, c_name, name);
            c.rtmidi_open_port(ptr, port_number, c_name.ptr);
            const id = device.id;
            device.ptr = ptr;
            device.name = c_name;
            device.guts = .{ .Output = .{} };
            return id;
        },
    }
}

pub fn deinit() void {
    quit = true;
    thread.join();
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        remove(i);
        if (devices[i].name) |n| allocator.free(n);
    }
    allocator.free(devices);
}
