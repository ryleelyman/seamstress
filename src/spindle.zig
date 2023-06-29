/// zig->lua and lua->zig interface
// @author ryleelyman
// @module seamstress
const std = @import("std");
const args = @import("args.zig");
const osc = @import("serialosc.zig");
const events = @import("events.zig");
const monome = @import("monome.zig");
const midi = @import("midi.zig");
const clock = @import("clock.zig");
const screen = @import("screen.zig");
const metro = @import("metros.zig");
const ziglua = @import("ziglua");
const c = @import("input.zig").c;

const Lua = ziglua.Lua;
var lvm: Lua = undefined;
var allocator: std.mem.Allocator = undefined;
const logger = std.log.scoped(.spindle);

pub fn init(prefix: []const u8, config: []const u8, alloc_pointer: std.mem.Allocator) !void {
    allocator = alloc_pointer;

    logger.info("starting lua vm", .{});
    lvm = try Lua.init(allocator);

    lvm.openLibs();

    lvm.newTable();

    register_seamstress("osc_send", ziglua.wrap(osc_send));

    register_seamstress("grid_set_led", ziglua.wrap(grid_set_led));
    register_seamstress("grid_all_led", ziglua.wrap(grid_all_led));
    register_seamstress("grid_rows", ziglua.wrap(grid_rows));
    register_seamstress("grid_cols", ziglua.wrap(grid_cols));
    register_seamstress("grid_set_rotation", ziglua.wrap(grid_set_rotation));
    register_seamstress("grid_tilt_enable", ziglua.wrap(grid_tilt_enable));
    register_seamstress("grid_tilt_disable", ziglua.wrap(grid_tilt_disable));

    register_seamstress("arc_set_led", ziglua.wrap(arc_set_led));
    register_seamstress("arc_all_led", ziglua.wrap(arc_all_led));

    register_seamstress("monome_refresh", ziglua.wrap(monome_refresh));
    register_seamstress("monome_intensity", ziglua.wrap(monome_intensity));

    register_seamstress("screen_refresh", ziglua.wrap(screen_refresh));
    register_seamstress("screen_pixel", ziglua.wrap(screen_pixel));
    register_seamstress("screen_pixel_rel", ziglua.wrap(screen_pixel_rel));
    register_seamstress("screen_line", ziglua.wrap(screen_line));
    register_seamstress("screen_line_rel", ziglua.wrap(screen_line_rel));
    register_seamstress("screen_rect", ziglua.wrap(screen_rect));
    register_seamstress("screen_rect_fill", ziglua.wrap(screen_rect_fill));
    register_seamstress("screen_text", ziglua.wrap(screen_text));
    register_seamstress("screen_text_center", ziglua.wrap(screen_text_center));
    register_seamstress("screen_text_right", ziglua.wrap(screen_text_right));
    register_seamstress("screen_color", ziglua.wrap(screen_color));
    register_seamstress("screen_clear", ziglua.wrap(screen_clear));
    register_seamstress("screen_set", ziglua.wrap(screen_set));
    register_seamstress("screen_show", ziglua.wrap(screen_show));
    register_seamstress("screen_arc", ziglua.wrap(screen_arc));
    register_seamstress("screen_circle", ziglua.wrap(screen_circle));
    register_seamstress("screen_circle_fill", ziglua.wrap(screen_circle_fill));
    register_seamstress("screen_move", ziglua.wrap(screen_move));
    register_seamstress("screen_move_rel", ziglua.wrap(screen_move_rel));
    register_seamstress("screen_get_pos", ziglua.wrap(screen_get_pos));
    register_seamstress("screen_get_size", ziglua.wrap(screen_get_size));
    register_seamstress("screen_get_text_size", ziglua.wrap(screen_get_text_size));

    register_seamstress("metro_start", ziglua.wrap(metro_start));
    register_seamstress("metro_stop", ziglua.wrap(metro_stop));
    register_seamstress("metro_set_time", ziglua.wrap(metro_set_time));

    register_seamstress("midi_write", ziglua.wrap(midi_write));

    register_seamstress("clock_get_tempo", ziglua.wrap(clock_get_tempo));
    register_seamstress("clock_get_beats", ziglua.wrap(clock_get_beats));
    register_seamstress("clock_internal_set_tempo", ziglua.wrap(clock_internal_set_tempo));
    register_seamstress("clock_internal_start", ziglua.wrap(clock_internal_start));
    register_seamstress("clock_internal_stop", ziglua.wrap(clock_internal_stop));
    register_seamstress("clock_cancel", ziglua.wrap(clock_cancel));

    register_seamstress("quit_lvm", ziglua.wrap(quit_lvm));

    register_seamstress("print", ziglua.wrap(lua_print));

    _ = lvm.pushString(args.local_port);
    lvm.setField(-2, "local_port");
    _ = lvm.pushString(args.remote_port);
    lvm.setField(-2, "remote_port");
    const prefixZ = try allocator.dupeZ(u8, prefix);
    defer allocator.free(prefixZ);
    _ = lvm.pushString(prefixZ);
    lvm.setField(-2, "prefix");

    lvm.setGlobal("_seamstress");

    const cmd = try std.fmt.allocPrint(allocator, "dofile(\"{s}\")\n", .{config});
    defer allocator.free(cmd);
    try run_code(cmd);
    try run_code("require('core/seamstress')");
}

fn register_seamstress(name: [:0]const u8, f: ziglua.CFn) void {
    lvm.pushFunction(f);
    lvm.setField(-2, name);
}

pub fn deinit() void {
    defer {
        logger.info("shutting down lua vm", .{});
        lvm.deinit();
        if (save_buf) |s| allocator.free(s);
    }
    logger.info("calling cleanup", .{});
    _ = lvm.getGlobal("_seamstress") catch unreachable;
    _ = lvm.getField(-1, "cleanup");
    lvm.remove(-2);
    docall(&lvm, 0, 0) catch unreachable;
}

pub fn startup(script: [:0]const u8) !void {
    _ = lvm.pushString(script);
    _ = try lvm.getGlobal("_startup");
    lvm.insert(1);
    try docall(&lvm, 1, 0);
}

/// sends OSC to specified address.
// users should use `osc:send` instead.
// @param address a table of the form `{host, port}`, both strings
// @param path a string representing an OSC path `/like/this`
// @param args an array whose data will be passed to OSC as arguments
// @see osc.send
// @usage osc.send({"localhost", "7777"}, "/send/stuff", {"a", 0, 0.5, nil, true})
// @function osc_send
fn osc_send(l: *Lua) i32 {
    var host: ?[*:0]const u8 = null;
    var port: ?[*:0]const u8 = null;
    var path: ?[*:0]const u8 = null;
    const num_args = l.getTop();
    if (num_args < 2) return 0;
    l.checkType(1, ziglua.LuaType.table);
    if (l.rawLen(1) != 2) {
        l.argError(1, "address should be a table in the form {host, port}");
    }

    l.pushNumber(1);
    _ = l.getTable(1);
    if (l.isString(-1)) {
        host = l.toString(-1) catch unreachable;
    } else {
        l.argError(1, "address should be a table in the form {host, port}");
    }
    l.pop(1);

    l.pushNumber(2);
    _ = l.getTable(1);
    if (l.isString(-1)) {
        port = l.toString(-1) catch unreachable;
    } else {
        l.argError(1, "address should be a table in the form {host, port}");
    }
    l.pop(1);

    l.checkType(2, ziglua.LuaType.string);
    path = l.toString(2) catch unreachable;
    if (host == null or port == null or path == null) {
        return 1;
    }

    var msg: []osc.Lo_Arg = undefined;
    if (num_args == 2) {
        osc.send(host.?, port.?, path.?, msg);
        return 0;
    }
    l.checkType(3, ziglua.LuaType.table);
    const len = l.rawLen(3);
    msg = allocator.alloc(osc.Lo_Arg, len) catch |err| {
        if (err == error.OutOfMemory) logger.err("out of memory!\n", .{});
        return 0;
    };
    defer allocator.free(msg);
    var i: usize = 1;
    while (i <= len) : (i += 1) {
        l.pushInteger(@intCast(i));
        _ = l.getTable(3);
        msg[i - 1] = switch (l.typeOf(-1)) {
            .nil => osc.Lo_Arg{ .Lo_Nil = false },
            .boolean => blk: {
                if (l.toBoolean(-1)) {
                    break :blk osc.Lo_Arg{ .Lo_True = true };
                } else {
                    break :blk osc.Lo_Arg{ .Lo_False = false };
                }
            },
            .number => osc.Lo_Arg{ .Lo_Double = l.toNumber(-1) catch unreachable },
            .string => blk: {
                const str = std.mem.span(l.toString(-1) catch unreachable);
                break :blk osc.Lo_Arg{ .Lo_String = str };
            },
            else => blk: {
                const str = std.fmt.allocPrint(allocator, "invalid osc argument type {s}", .{l.typeName(l.typeOf(-1))}) catch unreachable;
                l.raiseErrorStr(str[0..str.len :0], .{});
                break :blk osc.Lo_Arg{ .Lo_Nil = false };
            },
        };
        l.pop(1);
    }
    osc.send(host.?, port.?, path.?, msg);
    l.setTop(0);
    return 0;
}

/// sets grid led.
// users should use `grid:led` instead.
// @param md opaque pointer to monome device
// @param x x-coordinate for led (1-indexed)
// @param y y-coordinate for led (1-indexed)
// @param val brightness for led (0-15)
// @see grid:led
// @function grid_set_led
fn grid_set_led(l: *Lua) i32 {
    check_num_args(l, 4);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    const x: u8 = @intCast(l.checkInteger(2) - 1);
    const y: u8 = @intCast(l.checkInteger(3) - 1);
    const val: u8 = @intCast(l.checkInteger(4));
    md.grid_set_led(x, y, val);
    l.setTop(0);
    return 0;
}

/// sets all grid leds.
// users should use `grid:all` instead.
// @param md opaque pointer to monome device
// @param val brightness for led (0-15)
// @see grid:all
// @function grid_all_led
fn grid_all_led(l: *Lua) i32 {
    check_num_args(l, 2);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    const val: u8 = @intCast(l.checkInteger(2));
    md.grid_all_led(val);
    l.setTop(0);
    return 0;
}

/// reports number of rows of grid device.
// @param md opaque pointer to monome device
// @return number of rows
// @function grid_rows
fn grid_rows(l: *Lua) i32 {
    check_num_args(l, 1);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    l.setTop(0);
    l.pushInteger(md.rows);
    return 1;
}

/// reports number of columns of grid device.
// @param md opaque pointer to monome device
// @return number of columns
// @function grid_cols
fn grid_cols(l: *Lua) i32 {
    check_num_args(l, 1);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    l.setTop(0);
    l.pushInteger(md.cols);
    return 1;
}

/// sets grid rotation.
// users should use `grid:rotation` instead
// @param md opaque pointer to monome device
// @param rotation value to rotate
// @see grid:rotation
// @function grid_set_rotation
fn grid_set_rotation(l: *Lua) i32 {
    check_num_args(l, 2);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    const rotation: u16 = @intCast(l.checkInteger(2));
    md.set_rotation(rotation);
    l.setTop(0);
    return 0;
}

/// enable tilt data.
// users should use `grid:tilt` instead
// @param md opaque pointer to monome device
// @param sensor tilt sensor to enable
// @see grid:tilt
// @function grid_tilt_enable
fn grid_tilt_enable(l: *Lua) i32 {
    check_num_args(l, 2);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    const sensor: u8 = @intCast(l.checkInteger(2) - 1);
    md.tilt_set(sensor, 1);
    return 0;
}

/// disable tilt data.
// users should use `grid:tilt` instead
// @param md opaque pointer to monome device
// @param sensor tilt sensor to disable
// @see grid:tilt
// @function grid_tilt_disable
fn grid_tilt_disable(l: *Lua) i32 {
    check_num_args(l, 2);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    const sensor: u8 = @intCast(l.checkInteger(2) - 1);
    md.tilt_set(sensor, 0);
    return 0;
}

/// sets arc led.
// users should use `arc:led` instead
// @param md opaque pointer to monome device
// @param ring arc ring (1-based)
// @param led arc led (1-based)
// @param val led brightness (0-15)
// @see arc:led
// @function arc_set_led
fn arc_set_led(l: *Lua) i32 {
    check_num_args(l, 4);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    const ring: u8 = @intCast(l.checkInteger(2) - 1);
    const led: u8 = @intCast(l.checkInteger(3) - 1);
    const val: u8 = @intCast(l.checkInteger(4));
    md.arc_set_led(ring, led, val);
    l.setTop(0);
    return 0;
}

/// sets all arc leds.
// users should use `arc:all` instead
// @param md opaque pointser to monome device
// @param val led brightness (0-15)
// @see arc:all
// @function arc_all_led
fn arc_all_led(l: *Lua) i32 {
    check_num_args(l, 2);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    const val: u8 = @intCast(l.checkInteger(2));
    md.grid_all_led(val);
    l.setTop(0);
    return 0;
}

/// send dirty quads to monome device.
// users should use `grid:refresh` or `arc:refresh` instead
// @param md opaque pointer to monome device
// @see arc:refresh
// @see grid:refresh
// @function monome_refresh
fn monome_refresh(l: *Lua) i32 {
    check_num_args(l, 1);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    md.refresh();
    l.setTop(0);
    return 0;
}

/// sets maximum led brightness.
// users should use `grid:intensity` or `arc:intensity` instead
// @param md opaque pointer to monome device
// @param level maximum brightness level
// @see arc:intensity
// @see grid:intensity
// @function monome_intensity
fn monome_intensity(l: *Lua) i32 {
    check_num_args(l, 2);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const md = l.toUserdata(monome.Monome, 1) catch unreachable;
    const level: u8 = @intCast(l.checkInteger(2));
    md.intensity(level);
    l.setTop(0);
    return 0;
}

/// refreshes the screen.
// users should use `screen.redraw` instead
// @see screen.refresh
// @function screen_refresh
fn screen_refresh(l: *Lua) i32 {
    check_num_args(l, 0);
    screen.refresh();
    return 0;
}

/// moves the current location on the screen.
// users should use `screen.move` instead
// @param x x-coordinate (1-based)
// @param y y-coordinate (1-based)
// @see screen.move
// @function screen_move
fn screen_move(l: *Lua) i32 {
    check_num_args(l, 2);
    const x = l.checkInteger(1);
    const y = l.checkInteger(2);
    screen.move(@intCast(x - 1), @intCast(y - 1));
    return 0;
}

/// moves the current location on the screen relative to the current location.
// users should use `screen.move_rel` instead
// @param x relative x-coordinate
// @param y relative y-coordinate
// @see screen.move_rel
// @function screen_move_rel
fn screen_move_rel(l: *Lua) i32 {
    check_num_args(l, 2);
    const x = l.checkInteger(1);
    const y = l.checkInteger(2);
    screen.move_rel(@intCast(x), @intCast(y));
    return 0;
}

/// moves the current location on the screen relative to the current location.
// users should use `screen.get_pos` instead
// @treturn integer x x-coordinate
// @treturn integer y y-coordinate
// @see screen.get_pos
// @function screen_get_pos
fn screen_get_pos(l: *Lua) i32 {
    check_num_args(l, 2);
    const pos = screen.get_pos();
    screen.move_rel(pos.w + 1, pos.h + 1);
    return 2;
}

/// draws a single pixel.
// users should use `screen.pixel` instead
// @param x x-coordinate (1-based)
// @param y y-coordinate (1-based)
// @see screen.pixel
// @function screen_pixel
fn screen_pixel(l: *Lua) i32 {
    check_num_args(l, 2);
    const x = l.checkInteger(1);
    const y = l.checkInteger(2);
    screen.pixel(@intCast(x - 1), @intCast(y - 1));
    return 0;
}

/// draws a single pixel at the current location.
// users should use `screen.pixel_rel` instead
// @see screen.pixel_rel
// @function screen_pixel_rel
fn screen_pixel_rel(l: *Lua) i32 {
    check_num_args(l, 0);
    screen.pixel_rel();
    return 0;
}

/// draws a line.
// users should use `screen.line` instead
// @param bx terminal x-coordinate (1-based)
// @param by terminal y-coordinate (1-based)
// @see screen.line
// @function screen_line
fn screen_line(l: *Lua) i32 {
    check_num_args(l, 2);
    const bx = l.checkInteger(1);
    const by = l.checkInteger(2);
    screen.line(@intCast(bx - 1), @intCast(by - 1));
    return 0;
}

/// draws a line relative to the current location.
// users should use `screen.line_rel` instead
// @param bx terminal relative x-coordinate
// @param by terminal relative y-coordinate
// @see screen.line_rel
// @function screen_line_rel
fn screen_line_rel(l: *Lua) i32 {
    check_num_args(l, 2);
    const bx = l.checkInteger(1);
    const by = l.checkInteger(2);
    screen.line_rel(@intCast(bx), @intCast(by));
    return 0;
}

/// draws a rectangle.
// users should use `screen.rect` instead
// @param w width in pixels
// @param h height in pixels
// @see screen:rect
// @function screen_rect
fn screen_rect(l: *Lua) i32 {
    check_num_args(l, 2);
    const w = l.checkInteger(1);
    const h = l.checkInteger(2);
    screen.rect(@intCast(w), @intCast(h));
    l.setTop(0);
    return 0;
}

/// draws a filled rectangle.
// users should use `screen.rect` instead
// @param w width in pixels
// @param h height in pixels
// @see screen:rect
// @function screen_rect_fill
fn screen_rect_fill(l: *Lua) i32 {
    check_num_args(l, 2);
    const w = l.checkInteger(1);
    const h = l.checkInteger(2);
    screen.rect_fill(@intCast(w), @intCast(h));
    l.setTop(0);
    return 0;
}

/// draws text to the screen, left-aligned.
// users should use `screen.text` instead
// @param words text to draw to the screen
// @see screen.text
// @function screen_text
fn screen_text(l: *Lua) i32 {
    check_num_args(l, 1);
    const words = l.checkString(1);
    screen.text(std.mem.span(words));
    return 0;
}

/// draws text to the screen, center-aligned.
// users should use `screen.text_center` instead
// @param words text to draw to the screen
// @see screen.text_center
// @function screen_text_center
fn screen_text_center(l: *Lua) i32 {
    check_num_args(l, 1);
    const words = l.checkString(1);
    screen.text_center(std.mem.span(words));
    return 0;
}

/// draws text to the screen, right-aligned.
// users should use `screen.text_right` instead
// @param words text to draw to the screen
// @see screen.text
// @function screen_text_right
fn screen_text_right(l: *Lua) i32 {
    check_num_args(l, 1);
    const words = l.checkString(1);
    screen.text_right(std.mem.span(words));
    return 0;
}

/// draws a circle arc to the screen.
// users should use `screen.arc` instead
// @param radius radius of the circle in pixels
// @param theta_1 angle to start at (0-2*pi)
// @param theta_2 angle to finish at (0-2*pi)
// @see screen.arc
// @function screen_arc
fn screen_arc(l: *Lua) i32 {
    check_num_args(l, 3);
    const radius = l.checkInteger(1);
    const theta_1 = l.checkNumber(2);
    const theta_2 = l.checkNumber(3);
    screen.arc(@intCast(radius), theta_1, theta_2);
    l.setTop(0);
    return 0;
}

/// draws a circle to the screen.
// users should use `screen.circle` instead
// @param radius radius of the circle in pixels
// @see screen.circle
// @function screen_circle
fn screen_circle(l: *Lua) i32 {
    check_num_args(l, 1);
    const radius = l.checkInteger(1);
    screen.circle(@intCast(radius));
    l.setTop(0);
    return 0;
}

/// draws a filled-in circle to the screen.
// users should use `screen.circle_fill` instead
// @param radius radius of the circle in pixels
// @see screen.circle_fill
// @function screen_circle_fill
fn screen_circle_fill(l: *Lua) i32 {
    check_num_args(l, 1);
    const radius = l.checkInteger(1);
    screen.circle_fill(@intCast(radius));
    l.setTop(0);
    return 0;
}

/// sets screen color.
// users should use `screen.color` instead
// @param r red value (0-255)
// @param g green value (0-255)
// @param b blue value (0-255)
// @param a alpha value (0-255), defaults to 255
// @see screen:color
// @function screen_color
fn screen_color(l: *Lua) i32 {
    check_num_args(l, 4);
    const r: u8 = @intCast(l.checkInteger(1));
    const g: u8 = @intCast(l.checkInteger(2));
    const b: u8 = @intCast(l.checkInteger(3));
    const a: u8 = @intCast(l.checkInteger(4));
    screen.color(r, g, b, a);
    l.setTop(0);
    return 0;
}

/// clears the screen.
// users should use `screen.clear` instead
// @see screen.clear
// @function screen_clear
fn screen_clear(l: *Lua) i32 {
    check_num_args(l, 0);
    screen.clear();
    return 0;
}

/// sets which screen to draw to.
// users should use `screen.set` instead
// @see screen.set
// @function screen_set
fn screen_set(l: *Lua) i32 {
    check_num_args(l, 1);
    const value: usize = @intCast(l.checkInteger(1));
    if (value - 1 > 1 or value - 1 < 0) return 0;
    screen.set(value - 1);
    return 0;
}

/// unhides the params window
// @function screen_show
fn screen_show(l: *Lua) i32 {
    check_num_args(l, 0);
    screen.show(1);
    return 0;
}

/// returns the size of the current window
// @function screen_get_size
fn screen_get_size(l: *Lua) i32 {
    check_num_args(l, 0);
    const ret = screen.get_size();
    l.pushInteger(ret.w);
    l.pushInteger(ret.h);
    return 2;
}

/// returns the size in pixels of the given text.
// users should use `screen.get_text_size` instead
// @see screen.get_text_size
// @function screen_get_text_size
fn screen_get_text_size(l: *Lua) i32 {
    check_num_args(l, 1);
    const str = l.checkString(1);
    const ret = screen.get_text_size(str);
    l.pushInteger(ret.w);
    l.pushInteger(ret.h);
    return 2;
}

/// starts a new metro.
// users should use `metro:start` instead
// @param idx metro id (1-36)
// @param seconds float time at which to repeat
// @param count stage at which to stop
// @param stage stage at which to start
// @see metro:start
// @function metro_start
fn metro_start(l: *Lua) i32 {
    check_num_args(l, 4);
    const idx: u8 = @intCast(l.checkInteger(1) - 1);
    const seconds = l.checkNumber(2);
    const count = l.checkInteger(3);
    const stage = l.checkInteger(4);
    metro.start(idx, seconds, count, stage) catch unreachable;
    l.setTop(0);
    return 0;
}

/// stops a metro.
// users should use `metro:stop` instead
// @param idx metro id (1-36)
// @see metro:stop
// @function metro_stop
fn metro_stop(l: *Lua) i32 {
    check_num_args(l, 1);
    const idx: u8 = @intCast(l.checkInteger(1) - 1);
    metro.stop(idx);
    l.setTop(0);
    return 0;
}

/// set repetition time for a metro.
// users can use the `time` field on a metro instead.
// @param idx metro id (1-36)
// @param seconds new period (float)
// @function metro_set_time
fn metro_set_time(l: *Lua) i32 {
    check_num_args(l, 2);
    const idx: u8 = @intCast(l.checkInteger(1) - 1);
    const seconds = l.checkNumber(2);
    metro.set_period(idx, seconds) catch unreachable;
    l.setTop(0);
    return 0;
}

/// outputs midi data to device.
// users should use `midi:send` instead
// @param dev opaque pointer to midi device
// @param bytes table of small integers to write
// @see midi:send
// @function midi_write
fn midi_write(l: *Lua) i32 {
    check_num_args(l, 2);
    l.checkType(1, ziglua.LuaType.light_userdata);
    const dev = l.toUserdata(midi.Device, 1) catch unreachable;
    l.checkType(2, ziglua.LuaType.table);
    const len = l.rawLen(2);
    var i: c_longlong = 1;
    var msg = allocator.allocSentinel(u8, @intCast(len), 0) catch |err| {
        if (err == error.OutOfMemory) logger.err("out of memory!", .{});
        return 0;
    };
    while (i <= len) : (i += 1) {
        l.pushInteger(i);
        _ = l.getTable(2);
        msg[@intCast(i - 1)] = @intCast(l.toInteger(-1) catch unreachable);
    }
    midi.Device.Guts.output.write(dev, msg);
    allocator.free(msg);
    l.setTop(0);
    return 0;
}

/// returns current tempo.
// users should use `clock.get_tempo` instead
// @return bpm
// @see clock.get_tempo
// @function clock_get_tempo
fn clock_get_tempo(l: *Lua) i32 {
    check_num_args(l, 0);
    const bpm = clock.get_tempo();
    l.pushNumber(bpm);
    return 1;
}

/// returns current beat since the clock was last reset.
// users should use `clock.get_beats` instead
// @return beats
// @see clock.get_beats
// @function clock_get_beats
fn clock_get_beats(l: *Lua) i32 {
    const beats = clock.get_beats();
    l.pushNumber(beats);
    return 1;
}

/// sets internal clock tempo.
// users should use the clock param instead
// @param bpm
// @function clock_internal_set_tempo
fn clock_internal_set_tempo(l: *Lua) i32 {
    check_num_args(l, 1);
    const bpm = l.checkNumber(1);
    clock.set_tempo(bpm);
    return 0;
}

/// starts internal clock.
// users should use the clock param instead
// @function clock_internal_start
fn clock_internal_start(l: *Lua) i32 {
    check_num_args(l, 0);
    clock.start() catch unreachable;
    return 0;
}

/// stops internal clock.
// users should use the clock param instead
// @function clock_internal_stop
fn clock_internal_stop(l: *Lua) i32 {
    check_num_args(l, 0);
    clock.stop();
    return 0;
}

/// cancels coroutine.
// users should use `clock.cancel` instead
// @param idx id of coroutine to cancel
// @see clock.cancel
// @function clock_cancel
fn clock_cancel(l: *Lua) i32 {
    check_num_args(l, 1);
    const idx = l.checkInteger(1) - 1;
    l.setTop(0);
    if (idx < 0 or idx > 100) return 0;
    clock.cancel(@intCast(idx));
    return 0;
}

/// quits seamstress
// @function quit_lvm
fn quit_lvm(l: *Lua) i32 {
    check_num_args(l, 0);
    events.post(.{
        .Quit = {},
    });
    l.setTop(0);
    return 0;
}

fn check_num_args(l: *Lua, n: i8) void {
    if (l.getTop() != n) {
        l.raiseErrorStr("error: requires {d} arguments", .{n});
    }
}

inline fn push_lua_func(field: [:0]const u8, func: [:0]const u8) !void {
    _ = try lvm.getGlobal("_seamstress");
    _ = lvm.getField(-1, field);
    lvm.remove(-2);
    _ = lvm.getField(-1, func);
    lvm.remove(-2);
}

pub fn exec_code_line(line: [:0]const u8) !void {
    try handle_line(&lvm, line);
}

pub fn osc_event(
    from_host: []const u8,
    from_port: []const u8,
    path: []const u8,
    msg: []osc.Lo_Arg,
) !void {
    try push_lua_func("osc", "event");
    var path_copy = try allocator.allocSentinel(u8, path.len, 0);
    std.mem.copyForwards(u8, path_copy, path);
    _ = lvm.pushString(path_copy);
    lvm.createTable(@intCast(msg.len), 0);
    var i: usize = 0;
    while (i < msg.len) : (i += 1) {
        switch (msg[i]) {
            .Lo_Int32 => |a| lvm.pushInteger(a),
            .Lo_Float => |a| lvm.pushNumber(a),
            .Lo_String => |a| {
                _ = lvm.pushString(a);
            },
            .Lo_Blob => |a| {
                var ptr: [*]u8 = @ptrCast(a.dataptr.?);
                var len: usize = 0;
                _ = lvm.pushBytes(ptr[0..len]);
            },
            .Lo_Int64 => |a| lvm.pushInteger(a),
            .Lo_Double => |a| lvm.pushNumber(a),
            .Lo_Symbol => |a| _ = lvm.pushString(a),
            .Lo_Midi => |a| _ = lvm.pushBytes(&a),
            .Lo_True => |a| {
                _ = a;
                lvm.pushBoolean(true);
            },
            .Lo_False => |a| {
                _ = a;
                lvm.pushBoolean(false);
            },
            .Lo_Nil => |a| {
                _ = a;
                lvm.pushNil();
            },
            .Lo_Infinitum => |a| {
                _ = a;
                lvm.pushNumber(std.math.inf(f64));
            },
        }
        lvm.rawSetIndex(-2, @intCast(i + 1));
    }

    lvm.createTable(2, 0);
    var host_copy = try allocator.allocSentinel(u8, from_host.len, 0);
    std.mem.copyForwards(u8, host_copy, from_host);
    _ = lvm.pushString(host_copy);
    lvm.rawSetIndex(-2, 1);
    var port_copy = try allocator.allocSentinel(u8, from_port.len, 0);
    std.mem.copyForwards(u8, port_copy, from_port);
    _ = lvm.pushString(port_copy);
    lvm.rawSetIndex(-2, 2);

    // report(lvm, docall(lvm, 3, 0));
}

pub fn monome_add(dev: *monome.Monome) !void {
    const id = dev.id;
    const port = dev.name orelse return error.Fail;
    const name = switch (dev.m_type) {
        .Grid => "monome grid",
        .Arc => "monome arc",
    };
    try push_lua_func("monome", "add");
    lvm.pushInteger(@intCast(id + 1));
    var port_copy = try allocator.allocSentinel(u8, port.len, 0);
    defer allocator.free(port_copy);
    std.mem.copyForwards(u8, port_copy, port);
    _ = lvm.pushString(port_copy);
    _ = lvm.pushString(name);
    lvm.pushLightUserdata(dev);
    try docall(&lvm, 4, 0);
}

pub fn monome_remove(id: usize) !void {
    try push_lua_func("monome", "remove");
    lvm.pushInteger(@intCast(id + 1));
    try docall(&lvm, 1, 0);
}

pub fn grid_key(id: usize, x: i32, y: i32, state: i32) !void {
    try push_lua_func("grid", "key");
    lvm.pushInteger(@intCast(id + 1));
    lvm.pushInteger(x + 1);
    lvm.pushInteger(y + 1);
    lvm.pushInteger(state);
    try docall(&lvm, 4, 0);
}

pub fn grid_tilt(id: usize, sensor: i32, x: i32, y: i32, z: i32) !void {
    try push_lua_func("grid", "tilt");
    lvm.pushInteger(@intCast(id + 1));
    lvm.pushInteger(sensor + 1);
    lvm.pushInteger(x + 1);
    lvm.pushInteger(y + 1);
    lvm.pushInteger(z + 1);
    try docall(&lvm, 5, 0);
}

pub fn arc_delta(id: usize, ring: i32, delta: i32) !void {
    try push_lua_func("arc", "delta");
    lvm.pushInteger(@intCast(id + 1));
    lvm.pushInteger(ring + 1);
    lvm.pushInteger(delta);
    try docall(&lvm, 3, 0);
}

pub fn arc_key(id: usize, ring: i32, state: i32) !void {
    try push_lua_func("arc", "delta");
    lvm.pushInteger(@intCast(id + 1));
    lvm.pushInteger(ring + 1);
    lvm.pushInteger(state);
    try docall(&lvm, 3, 0);
}

pub fn screen_key(sym: i32, mod: u16, repeat: bool, state: bool, window: usize) !void {
    try push_lua_func("screen", "key");
    lvm.pushInteger(sym);
    lvm.pushInteger(mod);
    lvm.pushBoolean(repeat);
    lvm.pushInteger(if (state) 1 else 0);
    lvm.pushInteger(@intCast(window));
    try docall(&lvm, 5, 0);
}

pub fn screen_mouse(x: f64, y: f64, window: usize) !void {
    try push_lua_func("screen", "mouse");
    lvm.pushNumber(x + 1);
    lvm.pushNumber(y + 1);
    lvm.pushInteger(@intCast(window));
    try docall(&lvm, 3, 0);
}

pub fn screen_click(x: f64, y: f64, state: bool, button: u8, window: usize) !void {
    try push_lua_func("screen", "click");
    lvm.pushNumber(x + 1);
    lvm.pushNumber(y + 1);
    lvm.pushInteger(if (state) 1 else 0);
    lvm.pushInteger(button);
    lvm.pushInteger(@intCast(window));
    try docall(&lvm, 5, 0);
}

pub fn screen_scroll(x: f64, y: f64, window: usize) !void {
    try push_lua_func("screen", "scroll");
    lvm.pushNumber(x);
    lvm.pushNumber(y);
    lvm.pushInteger(@intCast(window));
    try docall(&lvm, 3, 0);
}

pub fn screen_resized(w: i32, h: i32, window: usize) !void {
    try push_lua_func("screen", "resized");
    lvm.pushInteger(w);
    lvm.pushInteger(h);
    lvm.pushInteger(@intCast(window));
    try docall(&lvm, 3, 0);
}

pub fn metro_event(id: u8, stage: i64) !void {
    try push_lua_func("metro", "event");
    lvm.pushInteger(id + 1);
    lvm.pushInteger(stage);
    try docall(&lvm, 2, 0);
}

pub fn midi_add(dev: *midi.Device) !void {
    try push_lua_func("midi", "add");
    _ = lvm.pushString(dev.name.?);
    switch (dev.guts) {
        midi.Dev_t.Input => lvm.pushBoolean(true),
        midi.Dev_t.Output => lvm.pushBoolean(false),
    }
    lvm.pushInteger(dev.id + 1);
    lvm.pushLightUserdata(dev);
    try docall(&lvm, 4, 0);
}

pub fn midi_remove(dev_type: midi.Dev_t, id: u32) !void {
    try push_lua_func("midi", "remove");
    switch (dev_type) {
        midi.Dev_t.Input => lvm.pushBoolean(true),
        midi.Dev_t.Output => lvm.pushBoolean(false),
    }
    lvm.pushInteger(id + 1);
    try docall(&lvm, 2, 0);
}

pub fn midi_event(id: u32, timestamp: f64, bytes: []const u8) !void {
    try push_lua_func("midi", "event");
    lvm.pushInteger(id + 1);
    lvm.pushNumber(timestamp);
    lvm.createTable(@intCast(bytes.len), 0);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        lvm.pushInteger(bytes[i]);
        lvm.rawSetIndex(-2, @intCast(i + 1));
    }
    try docall(&lvm, 3, 0);
}

// outward-facing clock resume
pub fn resume_clock(idx: u8) !void {
    const i = idx + 1;
    _ = try lvm.getGlobal("_seamstress");
    _ = lvm.getField(-1, "clock");
    _ = lvm.getField(-1, "threads");
    _ = lvm.getIndex(-1, i);
    var thread = try lvm.toThread(-1);
    lvm.pop(4);
    var top: i32 = 0;
    const status = thread.resumeThread(lvm, 0, &top) catch {
        _ = message_handler(&lvm);
        _ = lua_print(&lvm);
        lvm.setTop(0);
        return;
    };
    switch (status) {
        ziglua.ResumeStatus.ok => {
            clock.cancel(@intCast(idx));
            lvm.setTop(0);
            return;
        },
        ziglua.ResumeStatus.yield => {
            if (top < 2) lvm.raiseErrorStr("error: clock.sleep/sync requires at least 1 argument", .{});
            const sleep_type = lvm.checkInteger(1);
            switch (sleep_type) {
                0 => {
                    const seconds = lvm.checkNumber(2);
                    clock.schedule_sleep(@intCast(idx - 1), seconds);
                },
                1 => {
                    const beats = lvm.checkNumber(2);
                    lvm.pop(1);
                    const offset = if (top >= 3) blk: {
                        const val = lvm.checkNumber(3);
                        break :blk val;
                    } else 0;
                    clock.schedule_sync(@intCast(idx - 1), beats, offset);
                },
                else => {
                    lvm.setTop(0);
                    lvm.raiseErrorStr("expected CLOCK_SCHEDULE_SLEEP or CLOCK_SCHEDULE_SYNC, got {}", .{sleep_type});
                },
            }
        },
    }
    lvm.setTop(0);
}

pub fn clock_transport(ev_type: clock.Transport) !void {
    switch (ev_type) {
        clock.Transport.Start => try push_lua_func("transport", "start"),
        clock.Transport.Stop => try push_lua_func("transport", "stop"),
        clock.Transport.Reset => try push_lua_func("transport", "reset"),
    }
    try docall(&lvm, 0, 0);
}

// -------------------------------------------------------
// lua interpreter

fn lua_print(l: *Lua) i32 {
    _ = c.rl_set_prompt("");
    _ = c.rl_redisplay();
    const n = l.getTop();
    l.checkStackErr(2, "too many results to print");
    _ = l.getGlobal("_old_print") catch unreachable;
    l.insert(1);
    l.call(n, 0);
    _ = c.rl_set_prompt("> ");
    _ = c.rl_redisplay();
    return 0;
}

fn run_code(code: []const u8) !void {
    try dostring(&lvm, code, "s_run_code");
}

fn dostring(l: *Lua, str: []const u8, name: [:0]const u8) !void {
    try l.loadBuffer(str, name, ziglua.Mode.text);
    try docall(l, 0, 0);
}

var save_buf: ?[]u8 = null;

fn save_statement_buffer(buf: []u8) !void {
    if (save_buf != null) {
        allocator.free(save_buf.?);
    }
    save_buf = try allocator.alloc(u8, buf.len);
    std.mem.copyForwards(u8, save_buf.?, buf);
}

fn clear_statement_buffer() void {
    if (save_buf == null) {
        return;
    }
    allocator.free(save_buf.?);
    save_buf = null;
}
fn slice_from_ptr(ptr: [*:0]const u8) [:0]const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len :0];
}

fn message_handler(l: *Lua) i32 {
    var allocated = false;
    const msg = l.toString(1) catch blk: {
        l.callMeta(1, "__tostring") catch {
            const fmted = std.fmt.allocPrintZ(allocator, "(error object is a {s} value)", .{l.typeName(l.typeOf((1)))}) catch unreachable;
            allocated = true;
            break :blk fmted.ptr;
        };
        break :blk l.toString(1) catch unreachable;
    };
    const message = slice_from_ptr(msg);
    defer if (allocated) allocator.free(message);
    l.pop(1);
    l.traceback(l, message, 4);
    return 1;
}

fn docall(l: *Lua, nargs: i32, nres: i32) !void {
    const base = l.getTop() - nargs;
    l.pushFunction(ziglua.wrap(message_handler));
    l.insert(base);
    l.protectedCall(nargs, nres, base) catch {
        l.remove(base);
        _ = lua_print(l);
        return;
    };
    l.remove(base);
}

fn handle_line(l: *Lua, line: [:0]const u8) !void {
    l.setTop(0);
    _ = l.pushString(line);
    if (save_buf) |b| {
        _ = b;
        if (try statement(l)) {
            l.setTop(0);
            _ = c.rl_set_prompt(">... ");
            return;
        }
    } else {
        add_return(l) catch |err| {
            if (err == error.Syntax and try statement(l)) {
                l.setTop(0);
                _ = c.rl_set_prompt(">... ");
                return;
            }
        };
    }
    _ = c.rl_set_prompt("");
    _ = c.rl_redisplay();
    try docall(l, 0, ziglua.mult_return);
    if (l.getTop() == 0) {
        _ = c.rl_set_prompt("> ");
        _ = c.rl_redisplay();
    } else {
        _ = lua_print(l);
    }
    l.setTop(0);
}

fn statement(l: *Lua) !bool {
    const line = try l.toString(1);
    var buf: []u8 = undefined;
    if (save_buf) |b| {
        buf = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ b, line });
    } else {
        buf = try std.fmt.allocPrint(allocator, "{s}", .{line});
    }
    defer allocator.free(buf);
    l.loadBuffer(buf, "=stdin", ziglua.Mode.text) catch |err| {
        if (err != error.Syntax) return err;
        const msg = std.mem.span(try l.toString(-1));
        const eofmark = "<eof>";
        if ((msg.len >= eofmark.len) and std.mem.eql(u8, eofmark, msg[(msg.len - eofmark.len)..msg.len])) {
            l.pop(1);
            try save_statement_buffer(buf);
            return true;
        } else {
            clear_statement_buffer();
            l.remove(-2);
            _ = message_handler(l);
            _ = lua_print(l);
            return false;
        }
    };
    clear_statement_buffer();
    l.remove(1);
    return false;
}

fn add_return(l: *Lua) !void {
    const line = try l.toString(-1);
    const retline = try std.fmt.allocPrint(allocator, "return {s}", .{line});
    defer allocator.free(retline);
    l.loadBuffer(retline, "=stdin", ziglua.Mode.text) catch |err| {
        l.pop(1);
        return err;
    };
    l.remove(-2);
}
