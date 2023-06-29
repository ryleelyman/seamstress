const std = @import("std");
const spindle = @import("spindle.zig");
const osc = @import("serialosc.zig");
const monome = @import("monome.zig");
const screen = @import("screen.zig");
const clock = @import("clock.zig");
const midi = @import("midi.zig");

const logger = std.log.scoped(.events);

pub const Event = enum {
    // list of event types
    Quit,
    Exec_Code_Line,
    OSC,
    Monome_Add,
    Monome_Remove,
    Grid_Key,
    Grid_Tilt,
    Arc_Encoder,
    Arc_Key,
    Screen_Key,
    Screen_Mouse_Motion,
    Screen_Mouse_Click,
    Screen_Mouse_Scroll,
    Screen_Check,
    Screen_Resized,
    Metro,
    MIDI_Add,
    MIDI_Remove,
    MIDI,
    Clock_Resume,
    Clock_Transport,
};

pub const Data = union(Event) {
    Quit: void,
    Exec_Code_Line: event_exec_code_line,
    OSC: event_osc,
    Monome_Add: event_monome_add,
    Monome_Remove: event_monome_remove,
    Grid_Key: event_grid_key,
    Grid_Tilt: event_grid_tilt,
    Arc_Encoder: event_arc_delta,
    Arc_Key: event_arc_key,
    Screen_Key: event_screen_key,
    Screen_Mouse_Motion: event_screen_mouse_motion,
    Screen_Mouse_Click: event_screen_mouse_click,
    Screen_Mouse_Scroll: event_screen_mouse_scroll,
    Screen_Check: void,
    Screen_Resized: event_screen_resized,
    Metro: event_metro,
    MIDI_Add: event_midi_add,
    MIDI_Remove: event_midi_remove,
    MIDI: event_midi,
    Clock_Resume: event_resume,
    Clock_Transport: event_transport,
};

const event_exec_code_line = struct {
    line: [:0]const u8 = undefined,
};

const event_osc = struct {
    from_host: [:0]const u8 = undefined,
    from_port: [:0]const u8 = undefined,
    path: [:0]const u8 = undefined,
    msg: []osc.Lo_Arg = undefined,
};

const event_monome_add = struct {
    dev: *monome.Monome = undefined,
};

const event_monome_remove = struct {
    id: usize = undefined,
};

const event_grid_key = struct {
    id: usize = undefined,
    x: i32 = undefined,
    y: i32 = undefined,
    state: i32 = undefined,
};

const event_grid_tilt = struct {
    id: usize = undefined,
    sensor: i32 = undefined,
    x: i32 = undefined,
    y: i32 = undefined,
    z: i32 = undefined,
};

const event_arc_delta = struct {
    id: usize = undefined,
    ring: i32 = undefined,
    delta: i32 = undefined,
};

const event_arc_key = struct {
    id: usize = undefined,
    ring: i32 = undefined,
    state: i32 = undefined,
};

const event_screen_key = struct {
    sym: i32 = undefined,
    mod: u16 = undefined,
    repeat: bool = undefined,
    state: bool = undefined,
    window: usize = undefined,
};

const event_screen_mouse_motion = struct {
    x: f64 = undefined,
    y: f64 = undefined,
    window: usize = undefined,
};

const event_screen_mouse_click = struct {
    x: f64 = undefined,
    y: f64 = undefined,
    state: bool = undefined,
    button: u8 = undefined,
    window: usize = undefined,
};

const event_screen_mouse_scroll = struct {
    x: f64 = undefined,
    y: f64 = undefined,
    window: usize = undefined,
};

const event_screen_check = struct {};

const event_screen_resized = struct {
    w: i32 = undefined,
    h: i32 = undefined,
    window: usize = undefined,
};

const event_metro = struct {
    id: u8 = undefined,
    stage: i64 = undefined,
};

const event_midi_add = struct {
    dev: *midi.Device = undefined,
};

const event_midi_remove = struct {
    id: u32 = undefined,
    dev_type: midi.Dev_t = undefined,
};

const event_midi = struct {
    id: u32 = undefined,
    timestamp: f64 = undefined,
    message: []const u8 = undefined,
};

const event_resume = struct {
    id: u8 = undefined,
};

const event_transport = struct {
    transport: clock.Transport = undefined,
};

var allocator: std.mem.Allocator = undefined;

const Queue = struct {
    const Node = struct {
        // node
        next: ?*Node,
        prev: ?*Node,
        ev: *Data,
    };
    read_head: ?*Node,
    read_tail: ?*Node,
    read_size: usize,
    write_head: ?*Node,
    write_tail: ?*Node,
    write_size: usize,
    lock: std.Thread.Mutex,
    cond: std.Thread.Condition,
    inline fn get_new(self: *Queue) *Node {
        var node = self.write_head orelse {
            @panic("no nodes free!");
        };
        self.write_head = node.next;
        node.next = null;
        node.prev = null;
        std.debug.assert(self.write_size > 0);
        self.write_size -= 1;
        return node;
    }
    inline fn return_to_pool(self: *Queue, node: *Node) void {
        if (self.write_tail) |n| {
            self.write_tail = node;
            n.next = node;
            node.prev = n;
        } else {
            std.debug.assert(self.write_size == 0);
            self.write_head = node;
            self.write_tail = node;
        }
        self.write_size += 1;
    }
    fn push(self: *Queue, data: Data) void {
        var new_node = self.get_new();
        new_node.ev.* = data;
        if (self.read_tail) |n| {
            self.read_tail = new_node;
            n.next = new_node;
            new_node.prev = n;
        } else {
            std.debug.assert(self.read_size == 0);
            self.read_tail = new_node;
            self.read_head = new_node;
        }
        self.read_size += 1;
    }
    fn pop(self: *Queue) ?*Data {
        if (self.read_head) |n| {
            const ev = n.ev;
            self.read_head = n.next;
            self.return_to_pool(n);
            if (self.read_size == 1) self.read_tail = null;
            self.read_size -= 1;
            return ev;
        } else {
            std.debug.assert(self.read_size == 0);
            return null;
        }
    }
    fn deinit(self: *Queue) void {
        var node = self.write_head;
        while (node) |n| {
            node = n.next;
            allocator.destroy(n.ev);
            allocator.destroy(n);
        }
    }
};

var queue: Queue = undefined;

var quit: bool = false;

pub fn init(alloc_ptr: std.mem.Allocator) !void {
    allocator = alloc_ptr;
    queue = Queue{
        // queue
        .read_head = null,
        .read_tail = null,
        .read_size = 0,
        .write_head = null,
        .write_tail = null,
        .write_size = 0,
        .cond = .{},
        .lock = .{},
    };
    var i: u16 = 0;
    while (i < 1000) : (i += 1) {
        var node = try allocator.create(Queue.Node);
        var data = try allocator.create(Data);
        data.* = undefined;
        node.* = Queue.Node{ .ev = data, .next = null, .prev = null };
        queue.return_to_pool(node);
    }
}

pub fn loop() !void {
    while (!quit) {
        queue.lock.lock();
        while (queue.read_size == 0) {
            if (quit) break;
            queue.cond.wait(&queue.lock);
            continue;
        }
        const ev = queue.pop();
        queue.lock.unlock();
        if (ev != null) try handle(ev.?);
    }
}

pub fn free(event: *Data) void {
    switch (event.*) {
        .OSC => |e| {
            allocator.free(e.from_host);
            allocator.free(e.from_port);
            allocator.free(e.path);
            allocator.free(e.msg);
        },
        .Exec_Code_Line => |e| {
            allocator.free(e.line);
        },
        .MIDI => |e| {
            allocator.free(e.message);
        },
        else => {},
    }
}

pub fn post(event: Data) void {
    queue.lock.lock();
    queue.push(event);
    queue.cond.signal();
    queue.lock.unlock();
}

pub fn handle_pending() !void {
    var event: ?*Data = null;
    var done = false;
    while (!done) {
        queue.lock.lock();
        if (queue.read_size > 0) {
            event = queue.pop();
        } else {
            done = true;
        }
        queue.lock.unlock();
        if (event != null) try handle(event.?);
        event = null;
    }
}

pub fn deinit() void {
    free_pending();
    queue.deinit();
}

fn free_pending() void {
    var event: ?*Data = null;
    var done = false;
    while (!done) {
        if (queue.read_size > 0) {
            event = queue.pop();
        } else {
            done = true;
        }
        if (event) |ev| free(ev);
        event = null;
    }
}

fn handle(event: *Data) !void {
    switch (event.*) {
        .Quit => quit = true,
        .Exec_Code_Line => |e| try spindle.exec_code_line(e.line),
        .OSC => |e| try spindle.osc_event(e.from_host, e.from_port, e.path, e.msg),
        .Monome_Add => |e| try spindle.monome_add(e.dev),
        .Monome_Remove => |e| try spindle.monome_remove(e.id),
        .Grid_Key => |e| try spindle.grid_key(e.id, e.x, e.y, e.state),
        .Grid_Tilt => |e| try spindle.grid_tilt(e.id, e.sensor, e.x, e.y, e.z),
        .Arc_Encoder => |e| try spindle.arc_delta(e.id, e.ring, e.delta),
        .Arc_Key => |e| try spindle.arc_key(e.id, e.ring, e.state),
        .Screen_Key => |e| try spindle.screen_key(e.sym, e.mod, e.repeat, e.state, e.window),
        .Screen_Mouse_Motion => |e| try spindle.screen_mouse(e.x, e.y, e.window),
        .Screen_Mouse_Click => |e| try spindle.screen_click(e.x, e.y, e.state, e.button, e.window),
        .Screen_Mouse_Scroll => |e| try spindle.screen_scroll(e.x, e.y, e.window),
        .Screen_Check => screen.check(),
        .Screen_Resized => |e| try spindle.screen_resized(e.w, e.h, e.window),
        .Metro => |e| try spindle.metro_event(e.id, e.stage),
        .MIDI_Add => |e| try spindle.midi_add(e.dev),
        .MIDI_Remove => |e| try spindle.midi_remove(e.dev_type, e.id),
        .MIDI => |e| try spindle.midi_event(e.id, e.timestamp, e.message),
        .Clock_Resume => |e| try spindle.resume_clock(e.id),
        .Clock_Transport => |e| try spindle.clock_transport(e.transport),
    }
    free(event);
}
