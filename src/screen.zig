const std = @import("std");
const events = @import("events.zig");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
    @cInclude("SDL2/SDL_error.h");
    @cInclude("SDL2/SDL_render.h");
    @cInclude("SDL2/SDL_surface.h");
    @cInclude("SDL2/SDL_video.h");
});

var WIDTH: u16 = 256;
var HEIGHT: u16 = 128;
var ZOOM: u16 = 4;
var allocator: std.mem.Allocator = undefined;
const logger = std.log.scoped(.screen);

const Gui = struct {
    window: *c.SDL_Window = undefined,
    render: *c.SDL_Renderer = undefined,
    width: u16 = 256,
    height: u16 = 128,
    zoom: u16 = 4,
    x: c_int = 0,
    y: c_int = 0,
};

var windows: [2]Gui = undefined;
var current: usize = 0;

var font: *c.TTF_Font = undefined;
var thread: std.Thread = undefined;
var quit = false;

pub fn show(target: usize) void {
    c.SDL_ShowWindow(windows[target].window);
}

pub fn set(new: usize) void {
    current = new;
}

pub fn move(x: c_int, y: c_int) void {
    windows[current].x = x;
    windows[current].y = y;
}

pub fn move_rel(x: c_int, y: c_int) void {
    var gui = &windows[current];
    gui.x += x;
    gui.y += y;
}

pub fn get_pos() Size {
    return .{
        .w = windows[current].x,
        .h = windows[current].y,
    };
}

pub fn refresh() void {
    c.SDL_RenderPresent(windows[current].render);
}

pub fn clear() void {
    sdl_call(
        c.SDL_SetRenderDrawColor(windows[current].render, 0, 0, 0, 255),
        "screen.clear()",
    );
    sdl_call(
        c.SDL_RenderClear(windows[current].render),
        "screen.clear()",
    );
}

pub fn color(r: u8, g: u8, b: u8, a: u8) void {
    sdl_call(
        c.SDL_SetRenderDrawColor(windows[current].render, r, g, b, a),
        "screen.color()",
    );
}

pub fn pixel(x: c_int, y: c_int) void {
    sdl_call(
        c.SDL_RenderDrawPoint(windows[current].render, x, y),
        "screen.pixel()",
    );
}

pub fn pixel_rel() void {
    const gui = windows[current];
    sdl_call(
        c.SDL_RenderDrawPoint(gui.render, gui.x, gui.y),
        "screen.pixel_rel()",
    );
}

pub fn line(bx: c_int, by: c_int) void {
    const gui = windows[current];
    sdl_call(
        c.SDL_RenderDrawLine(gui.render, gui.x, gui.y, bx, by),
        "screen.line()",
    );
}

pub fn line_rel(bx: c_int, by: c_int) void {
    const gui = windows[current];
    sdl_call(
        c.SDL_RenderDrawLine(gui.render, gui.x, gui.y, gui.x + bx, gui.y + by),
        "screen.line()",
    );
}

pub fn rect(w: i32, h: i32) void {
    const gui = windows[current];
    var r = c.SDL_Rect{ .x = gui.x, .y = gui.y, .w = w, .h = h };
    sdl_call(
        c.SDL_RenderDrawRect(gui.render, &r),
        "screen.rect()",
    );
}

pub fn rect_fill(w: i32, h: i32) void {
    const gui = windows[current];
    var r = c.SDL_Rect{ .x = gui.x, .y = gui.y, .w = w, .h = h };
    sdl_call(
        c.SDL_RenderFillRect(gui.render, &r),
        "screen.rect_fill()",
    );
}

pub fn text(words: [:0]const u8) void {
    if (words.len == 0) return;
    var r: u8 = undefined;
    var g: u8 = undefined;
    var b: u8 = undefined;
    var a: u8 = undefined;
    const gui = windows[current];
    _ = c.SDL_GetRenderDrawColor(gui.render, &r, &g, &b, &a);
    var col = c.SDL_Color{ .r = r, .g = g, .b = b, .a = a };
    var text_surf = c.TTF_RenderText_Solid(font, words, col);
    var texture = c.SDL_CreateTextureFromSurface(gui.render, text_surf);
    const rectangle = c.SDL_Rect{ .x = gui.x, .y = gui.y, .w = text_surf.*.w, .h = text_surf.*.h };
    sdl_call(
        c.SDL_RenderCopy(gui.render, texture, null, &rectangle),
        "screen.text()",
    );
    c.SDL_DestroyTexture(texture);
    c.SDL_FreeSurface(text_surf);
}

pub fn text_center(words: [:0]const u8) void {
    if (words.len == 0) return;
    var r: u8 = undefined;
    var g: u8 = undefined;
    var b: u8 = undefined;
    var a: u8 = undefined;
    const gui = windows[current];
    _ = c.SDL_GetRenderDrawColor(gui.render, &r, &g, &b, &a);
    var col = c.SDL_Color{ .r = r, .g = g, .b = b, .a = a };
    var text_surf = c.TTF_RenderText_Solid(font, words, col);
    var texture = c.SDL_CreateTextureFromSurface(gui.render, text_surf);
    const radius = @divTrunc(text_surf.*.w, 2);
    const rectangle = c.SDL_Rect{ .x = gui.x - radius, .y = gui.y, .w = text_surf.*.w, .h = text_surf.*.h };
    sdl_call(
        c.SDL_RenderCopy(gui.render, texture, null, &rectangle),
        "screen.text()",
    );
    c.SDL_DestroyTexture(texture);
    c.SDL_FreeSurface(text_surf);
}

pub fn text_right(words: [:0]const u8) void {
    if (words.len == 0) return;
    var r: u8 = undefined;
    var g: u8 = undefined;
    var b: u8 = undefined;
    var a: u8 = undefined;
    const gui = windows[current];
    _ = c.SDL_GetRenderDrawColor(gui.render, &r, &g, &b, &a);
    var col = c.SDL_Color{ .r = r, .g = g, .b = b, .a = a };
    var text_surf = c.TTF_RenderText_Solid(font, words, col);
    var texture = c.SDL_CreateTextureFromSurface(gui.render, text_surf);
    const width = text_surf.*.w;
    const rectangle = c.SDL_Rect{ .x = gui.x - width, .y = gui.y, .w = width, .h = text_surf.*.h };
    sdl_call(
        c.SDL_RenderCopy(gui.render, texture, null, &rectangle),
        "screen.text()",
    );
    c.SDL_DestroyTexture(texture);
    c.SDL_FreeSurface(text_surf);
}

pub fn arc(radius: i32, theta_1: f64, theta_2: f64) void {
    std.debug.assert(0 <= theta_1);
    std.debug.assert(theta_1 <= theta_2);
    std.debug.assert(theta_2 <= std.math.tau);
    const angle_length = (theta_2 - theta_1) * @as(f64, @floatFromInt(radius));
    const perimeter_estimate: usize = 2 * @as(usize, @intFromFloat(angle_length)) + 9;
    const gui = windows[current];
    var points = std.ArrayList(c.SDL_Point).initCapacity(allocator, perimeter_estimate) catch @panic("OOM!");
    defer points.deinit();
    var offset_x: i32 = 0;
    var offset_y: i32 = radius;
    var d = radius - 1;
    while (offset_y >= offset_x) {
        const pts = [8]c.SDL_Point{ .{
            .x = gui.x + offset_x,
            .y = gui.y + offset_y,
        }, .{
            .x = gui.x + offset_y,
            .y = gui.y + offset_x,
        }, .{
            .x = gui.x - offset_x,
            .y = gui.y + offset_y,
        }, .{
            .x = gui.x - offset_y,
            .y = gui.y + offset_x,
        }, .{
            .x = gui.x + offset_x,
            .y = gui.y - offset_y,
        }, .{
            .x = gui.x + offset_y,
            .y = gui.y - offset_x,
        }, .{
            .x = gui.x - offset_x,
            .y = gui.y - offset_y,
        }, .{
            .x = gui.x - offset_y,
            .y = gui.y - offset_x,
        } };
        for (pts) |pt| {
            const num: f64 = @floatFromInt(pt.x);
            const denom: f64 = @floatFromInt(pt.y);
            const theta = std.math.atan(num / denom);
            if (theta_1 <= theta and theta <= theta_2) {
                points.appendAssumeCapacity(pt);
            }
        }
        if (d >= 2 * offset_x) {
            d -= 2 * offset_x + 1;
            offset_x += 1;
        } else if (d < 2 * (radius - offset_y)) {
            d += 2 * offset_y - 1;
            offset_y -= 1;
        } else {
            d += 2 * (offset_y - offset_x - 1);
            offset_y -= 1;
            offset_x += 1;
        }
    }
    const slice = points.items;
    sdl_call(
        c.SDL_RenderDrawPoints(gui.render, slice.ptr, @intCast(slice.len)),
        "screen.arc()",
    );
}

pub fn circle(radius: i32) void {
    const perimeter_estimate: usize = @intFromFloat(2 * std.math.tau * @as(f64, @floatFromInt(radius)));
    const gui = windows[current];
    var points = std.ArrayList(c.SDL_Point).initCapacity(allocator, perimeter_estimate) catch @panic("OOM!");
    defer points.deinit();
    var offset_x: i32 = 0;
    var offset_y: i32 = radius;
    var d = radius - 1;
    while (offset_y >= offset_x) {
        const pts = [8]c.SDL_Point{ .{
            .x = gui.x + offset_x,
            .y = gui.y + offset_y,
        }, .{
            .x = gui.x + offset_y,
            .y = gui.y + offset_x,
        }, .{
            .x = gui.x - offset_x,
            .y = gui.y + offset_y,
        }, .{
            .x = gui.x - offset_y,
            .y = gui.y + offset_x,
        }, .{
            .x = gui.x + offset_x,
            .y = gui.y - offset_y,
        }, .{
            .x = gui.x + offset_y,
            .y = gui.y - offset_x,
        }, .{
            .x = gui.x - offset_x,
            .y = gui.y - offset_y,
        }, .{
            .x = gui.x - offset_y,
            .y = gui.y - offset_x,
        } };
        points.appendSliceAssumeCapacity(&pts);
        if (d >= 2 * offset_x) {
            d -= 2 * offset_x + 1;
            offset_x += 1;
        } else if (d < 2 * (radius - offset_y)) {
            d += 2 * offset_y - 1;
            offset_y -= 1;
        } else {
            d += 2 * (offset_y - offset_x - 1);
            offset_y -= 1;
            offset_x += 1;
        }
    }
    const slice = points.items;
    sdl_call(
        c.SDL_RenderDrawPoints(gui.render, slice.ptr, @intCast(slice.len)),
        "screen.circle()",
    );
}

pub fn circle_fill(radius: i32) void {
    const r = if (radius < 0) -radius else radius;
    const rsquared = radius * radius;
    const gui = windows[current];
    var points = std.ArrayList(c.SDL_Point).initCapacity(allocator, @intCast(4 * rsquared + 2)) catch @panic("OOM!");
    defer points.deinit();
    var i = -r;
    while (i <= r) : (i += 1) {
        var j = -r;
        while (j <= r) : (j += 1) {
            if (i * i + j * j < rsquared) points.appendAssumeCapacity(.{
                .x = gui.x + i,
                .y = gui.y + j,
            });
        }
    }
    const slice = points.items;
    sdl_call(
        c.SDL_RenderDrawPoints(gui.render, slice.ptr, @intCast(slice.len)),
        "screen.circle_fill()",
    );
}

const Size = struct {
    w: i32,
    h: i32,
};

pub fn get_text_size(str: [*:0]const u8) Size {
    var w: i32 = undefined;
    var h: i32 = undefined;
    sdl_call(c.TTF_SizeText(font, str, &w, &h), "screen.get_text_size()");
    return .{ .w = w, .h = h };
}

pub fn get_size() Size {
    return .{
        .w = windows[current].width,
        .h = windows[current].height,
    };
}

pub fn init(alloc_pointer: std.mem.Allocator, width: u16, height: u16, resources: []const u8) !void {
    allocator = alloc_pointer;
    HEIGHT = height;
    WIDTH = width;

    if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
        logger.err("screen.init(): {s}\n", .{c.SDL_GetError()});
        return error.Fail;
    }

    if (c.TTF_Init() < 0) {
        logger.err("screen.init(): {s}\n", .{c.TTF_GetError()});
        return error.Fail;
    }

    const filename = try std.fmt.allocPrintZ(allocator, "{s}/04b03.ttf", .{resources});
    defer allocator.free(filename);
    var f = c.TTF_OpenFont(filename, 8);
    font = f orelse {
        logger.err("screen.init(): {s}\n", .{c.TTF_GetError()});
        return error.Fail;
    };

    var w = c.SDL_CreateWindow(
        "seamstress",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        WIDTH * ZOOM,
        HEIGHT * ZOOM,
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
    );
    var window = w orelse {
        logger.err("screen.init(): {s}\n", .{c.SDL_GetError()});
        return error.Fail;
    };

    var r = c.SDL_CreateRenderer(window, 0, 0);
    var render = r orelse {
        logger.err("screen.init(): {s}\n", .{c.SDL_GetError()});
        return error.Fail;
    };

    c.SDL_SetWindowMinimumSize(window, WIDTH, HEIGHT);
    windows[0] = .{
        .window = window,
        .render = render,
        .zoom = ZOOM,
    };
    set(0);
    window_rect(&windows[current]);
    clear();
    refresh();

    w = c.SDL_CreateWindow(
        "seamstress params",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        WIDTH * ZOOM,
        HEIGHT * ZOOM,
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
    );
    window = w orelse {
        logger.err("screen.init(): {s}\n", .{c.SDL_GetError()});
        return error.Fail;
    };
    r = c.SDL_CreateRenderer(window, 0, 0);
    render = r orelse {
        logger.err("screen.init(): {s}\n", .{c.SDL_GetError()});
        return error.Fail;
    };
    windows[1] = .{
        .window = window,
        .render = render,
        .zoom = ZOOM,
    };
    set(1);
    window_rect(&windows[current]);
    clear();
    refresh();
    set(0);
    thread = try std.Thread.spawn(.{}, loop, .{});
}

fn window_rect(gui: *Gui) void {
    var xsize: i32 = undefined;
    var ysize: i32 = undefined;
    var xzoom: u16 = 1;
    var yzoom: u16 = 1;
    const oldzoom = gui.zoom;
    c.SDL_GetWindowSize(gui.window, &xsize, &ysize);
    while ((1 + xzoom) * WIDTH <= xsize) : (xzoom += 1) {}
    while ((1 + yzoom) * HEIGHT <= ysize) : (yzoom += 1) {}
    gui.zoom = if (xzoom < yzoom) xzoom else yzoom;
    const uxsize: u16 = @intCast(xsize);
    const uysize: u16 = @intCast(ysize);
    gui.width = @divFloor(uxsize, gui.zoom);
    gui.height = @divFloor(uysize, gui.zoom);
    gui.x = @divFloor(gui.x * oldzoom, gui.zoom);
    gui.y = @divFloor(gui.y * oldzoom, gui.zoom);
    sdl_call(c.SDL_RenderSetScale(
        gui.render,
        @floatFromInt(gui.zoom),
        @floatFromInt(gui.zoom),
    ), "window_rect()");
}

pub fn check() void {
    var ev: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&ev) != 0) {
        switch (ev.type) {
            c.SDL_KEYUP, c.SDL_KEYDOWN => {
                const event = .{
                    .Screen_Key = .{
                        .sym = ev.key.keysym.sym,
                        .mod = ev.key.keysym.mod,
                        .repeat = ev.key.repeat > 0,
                        .state = ev.key.state == c.SDL_PRESSED,
                        .window = ev.key.windowID,
                    },
                };
                events.post(event);
            },
            c.SDL_QUIT => {
                events.post(.{ .Quit = {} });
                quit = true;
            },
            c.SDL_MOUSEMOTION => {
                const zoom: f64 = @floatFromInt(windows[ev.button.windowID - 1].zoom);
                const x: f64 = @floatFromInt(ev.button.x);
                const y: f64 = @floatFromInt(ev.button.y);
                const event = .{
                    .Screen_Mouse_Motion = .{
                        .x = x / zoom,
                        .y = y / zoom,
                        .window = ev.motion.windowID,
                    },
                };
                events.post(event);
            },
            c.SDL_MOUSEBUTTONDOWN, c.SDL_MOUSEBUTTONUP => {
                const zoom: f64 = @floatFromInt(windows[ev.button.windowID - 1].zoom);
                const x: f64 = @floatFromInt(ev.button.x);
                const y: f64 = @floatFromInt(ev.button.y);
                const event = .{
                    .Screen_Mouse_Click = .{
                        .state = ev.button.state == c.SDL_PRESSED,
                        .x = x / zoom,
                        .y = y / zoom,
                        .button = ev.button.button,
                        .window = ev.button.windowID,
                    },
                };
                events.post(event);
            },
            c.SDL_MOUSEWHEEL => {
                const flipped = ev.wheel.direction == c.SDL_MOUSEWHEEL_NORMAL;
                const x = ev.wheel.preciseX;
                const y = if (flipped) -1 * ev.wheel.preciseY else ev.wheel.preciseY;
                const event = .{
                    .Screen_Mouse_Scroll = .{
                        .x = x,
                        .y = y,
                        .window = ev.window.windowID,
                    },
                };
                events.post(event);
            },
            c.SDL_WINDOWEVENT => {
                switch (ev.window.event) {
                    c.SDL_WINDOWEVENT_CLOSE => {
                        if (ev.window.windowID == 1) {
                            events.post(.{ .Quit = {} });
                            quit = true;
                        } else {
                            c.SDL_HideWindow(windows[ev.window.windowID - 1].window);
                        }
                    },
                    c.SDL_WINDOWEVENT_EXPOSED => {
                        const old = current;
                        set(ev.window.windowID - 1);
                        refresh();
                        set(old);
                    },
                    c.SDL_WINDOWEVENT_RESIZED => {
                        const old = current;
                        const id = ev.window.windowID - 1;
                        set(id);
                        window_rect(&windows[current]);
                        refresh();
                        set(old);
                        const event = .{
                            .Screen_Resized = .{
                                .w = windows[id].width,
                                .h = windows[id].height,
                                .window = id + 1,
                            },
                        };
                        events.post(event);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

pub fn deinit() void {
    quit = true;
    thread.join();
    c.TTF_CloseFont(font);
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        c.SDL_DestroyRenderer(windows[i].render);
        c.SDL_DestroyWindow(windows[i].window);
    }
    c.TTF_Quit();
    c.SDL_Quit();
}

fn loop() void {
    while (!quit) {
        events.post(.{ .Screen_Check = {} });
        std.time.sleep(10 * std.time.ns_per_ms);
    }
}

fn sdl_call(err: c_int, name: []const u8) void {
    if (err < -1) {
        logger.err("{s}: error: {s}", .{ name, c.SDL_GetError() });
    }
}
