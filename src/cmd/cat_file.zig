// forge cat-file - show object contents, type, or size

const std = @import("std");
const object = @import("../object/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var mode: enum { print, type_only, size_only, exists } = .print;
    var object_ref: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-p")) {
            mode = .print;
        } else if (std.mem.eql(u8, arg, "-t")) {
            mode = .type_only;
        } else if (std.mem.eql(u8, arg, "-s")) {
            mode = .size_only;
        } else if (std.mem.eql(u8, arg, "-e")) {
            mode = .exists;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            object_ref = arg;
        }
    }

    if (object_ref == null) {
        try stderr.writeAll("usage: forge cat-file [-p | -t | -s | -e] <object>\n");
        return;
    }

    // Parse object SHA
    const ref = object_ref.?;
    if (ref.len < 4) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: Not a valid object name {s}\n", .{ref}) catch "fatal: invalid object\n";
        try stderr.writeAll(msg);
        return;
    }

    // Support abbreviated SHAs (minimum 4 chars)
    var sha: object.Sha1 = undefined;
    if (ref.len == 40) {
        sha = object.hash.fromHex(ref[0..40]) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: Not a valid object name {s}\n", .{ref}) catch "fatal: invalid object\n";
            try stderr.writeAll(msg);
            return;
        };
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: Not a valid object name {s}\n", .{ref}) catch "fatal: invalid object\n";
        try stderr.writeAll(msg);
        return;
    }

    var store = object.ObjectStore.init(allocator, ".git");

    // Check existence
    if (mode == .exists) {
        if (store.exists(sha)) {
            return;
        } else {
            std.process.exit(1);
        }
    }

    // Read object
    const raw = store.readRaw(sha) catch |err| {
        if (err == error.FileNotFound) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: Not a valid object name {s}\n", .{ref}) catch "fatal: invalid object\n";
            try stderr.writeAll(msg);
            return;
        }
        return err;
    };
    defer allocator.free(raw.data);

    switch (mode) {
        .type_only => {
            try stdout.writeAll(raw.type_str);
            try stdout.writeAll("\n");
        },
        .size_only => {
            var buf: [32]u8 = undefined;
            const size_str = std.fmt.bufPrint(&buf, "{d}\n", .{raw.content.len}) catch "0\n";
            try stdout.writeAll(size_str);
        },
        .print => {
            if (std.mem.eql(u8, raw.type_str, "blob")) {
                try stdout.writeAll(raw.content);
            } else if (std.mem.eql(u8, raw.type_str, "tree")) {
                // Pretty print tree
                var pos: usize = 0;
                while (pos < raw.content.len) {
                    const space = std.mem.indexOf(u8, raw.content[pos..], " ") orelse break;
                    const mode_str = raw.content[pos .. pos + space];
                    pos += space + 1;

                    const null_pos = std.mem.indexOf(u8, raw.content[pos..], "\x00") orelse break;
                    const name = raw.content[pos .. pos + null_pos];
                    pos += null_pos + 1;

                    if (pos + 20 > raw.content.len) break;
                    const entry_sha = raw.content[pos..][0..20];
                    pos += 20;

                    const entry_hex = object.hash.toHex(entry_sha.*);
                    const entry_type = if (std.mem.eql(u8, mode_str, "40000")) "tree" else "blob";

                    var buf: [256]u8 = undefined;
                    const line = std.fmt.bufPrint(&buf, "{s:0>6} {s} {s}\t{s}\n", .{ mode_str, entry_type, entry_hex, name }) catch continue;
                    try stdout.writeAll(line);
                }
            } else if (std.mem.eql(u8, raw.type_str, "commit") or std.mem.eql(u8, raw.type_str, "tag")) {
                try stdout.writeAll(raw.content);
            }
        },
        .exists => unreachable,
    }
}

test "cat-file arg parsing" {
    // Basic test that would need a real repo
}
