const std = @import("std");

pub var script_file: []const u8 = "script";
pub var local_port: [:0]const u8 = "7777";
pub var remote_port: [:0]const u8 = "6666";
pub var socket_port: [:0]const u8 = "8888";
pub var width: [:0]const u8 = "256";
pub var height: [:0]const u8 = "128";
pub var watch = false;
pub var args: std.process.ArgIterator = undefined;

pub const CreateOptions = enum { script, project, norns_project, example };

pub fn parse(location: []const u8, allocator: std.mem.Allocator) !?CreateOptions {
    var double_dip = false;
    var list_examples = false;
    args = try std.process.argsWithAllocator(allocator);
    var i: u8 = 0;
    while (args.next()) |arg| : (i += 1) {
        if (i == 0) {
            continue;
        }
        if (i == 1) {
            if (std.mem.eql(u8, arg, "create-script")) {
                return .script;
            } else if (std.mem.eql(u8, arg, "create-project")) {
                return .project;
            } else if (std.mem.eql(u8, arg, "create-norns-project")) {
                return .norns_project;
            }
        }
        if ((arg.len != 2) or (arg[0] != '-')) {
            if (!double_dip) {
                script_file = arg;
                double_dip = true;
                continue;
            } else break;
        }
        switch (arg[1]) {
            'b' => {
                if (args.next()) |next| {
                    remote_port = next;
                    continue;
                }
            },
            'e' => {
                if (args.next()) |next| {
                    script_file = next;
                    list_examples = true;
                    continue;
                } else {
                    list_examples = true;
                    break;
                }
            },
            'l' => {
                if (args.next()) |next| {
                    local_port = next;
                    continue;
                }
            },
            'p' => {
                if (args.next()) |next| {
                    socket_port = next;
                    continue;
                }
            },
            's' => {
                if (args.next()) |next| {
                    script_file = next;
                    continue;
                }
            },
            'w' => {
                watch = true;
                continue;
            },
            'x' => {
                if (args.next()) |next| {
                    width = next;
                    continue;
                }
            },
            'y' => {
                if (args.next()) |next| {
                    height = next;
                    continue;
                }
            },
            'h' => {
                try print_usage();
                std.process.exit(0);
            },
            else => {
                break;
            },
        }
        break;
    } else {
        const suffix = ".lua";
        if (std.mem.endsWith(u8, script_file, suffix))
            script_file = script_file[0..(script_file.len - suffix.len)];
        if (list_examples) return .example;
        return null;
    }
    if (list_examples) {
        try print_examples(location);
        std.process.exit(0);
    }
    try print_usage();
    std.process.exit(1);
}

fn print_usage() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    try stdout.print("USAGE: seamstress [script] [args]\n\n", .{});
    try stdout.print("[script] (optional) should be the name of a lua file in CWD or ~/seamstress\n", .{});
    try stdout.print("[args]   (optional) should be one or more of the following\n", .{});
    try stdout.print("-s       override user script [current {s}]\n", .{script_file});
    try stdout.print("-e       list or load example scripts\n", .{});
    try stdout.print("-l       override OSC listen port [current {s}]\n", .{local_port});
    try stdout.print("-b       override OSC broadcast port [current {s}]\n", .{remote_port});
    try stdout.print("-p       override socket listen port [current {s}]\n", .{socket_port});
    try stdout.print("-w       watch the directory containing the script file for changes\n", .{});
    try stdout.print("-x       override window width [current {s}]\n", .{width});
    try stdout.print("-y       override window height [current {s}]\n", .{height});
    try bw.flush();
}

fn print_examples(location: []const u8) !void {
    var buf: [1024 * 32]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .{
        .buffer = &buf,
        .end_index = 0,
    };
    var allocator = fba.allocator();
    const path = try std.fs.path.join(allocator, &.{ location, "..", "share", "seamstress" });
    defer allocator.free(path);
    const prefix = try std.fs.realpathAlloc(allocator, path);
    defer allocator.free(prefix);
    var dir = try std.fs.openDirAbsolute(prefix, .{});
    defer dir.close();
    var iterable = try dir.openIterableDir("examples", .{ .access_sub_paths = false });
    defer iterable.close();
    var walker = try iterable.walk(allocator);
    defer walker.deinit();

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    try stdout.print("EXAMPLE SCRIPTS:\nrerun seamstress with -e SCRIPTNAME to copy and run the example script.\n", .{});
    while (try walker.next()) |file| {
        const suffix = ".lua";
        if (std.mem.endsWith(u8, file.basename, suffix)) {
            const name = file.basename[0..(file.basename.len - suffix.len)];
            try stdout.print("{s}\n", .{name});
        }
    }
    try bw.flush();
}
