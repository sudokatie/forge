// forge ls-files - show index entries

const std = @import("std");
const index_mod = @import("../index/mod.zig");
const object = @import("../object/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    var staged = false;
    var show_cached = false;
    var show_deleted = false;
    var show_modified = false;
    var show_others = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--staged")) {
            staged = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cached")) {
            show_cached = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--deleted")) {
            show_deleted = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--modified")) {
            show_modified = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--others")) {
            show_others = true;
        }
    }

    // Default to showing cached files
    if (!staged and !show_cached and !show_deleted and !show_modified and !show_others) {
        show_cached = true;
    }

    var idx = try index_mod.Index.read(allocator, ".git");
    defer idx.deinit();

    const cwd = std.fs.cwd();

    if (staged) {
        // Show staged files with mode, sha, stage, path
        for (idx.entries) |entry| {
            const hex = object.hash.toHex(entry.sha);
            const stage = (entry.flags >> 12) & 0x3;
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{o:0>6} {s} {d}\t{s}\n", .{ entry.mode, hex, stage, entry.path }) catch continue;
            try stdout.writeAll(line);
        }
    } else {
        for (idx.entries) |entry| {
            const file_exists = cwd.access(entry.path, .{}) != error.FileNotFound;

            if (show_cached and file_exists) {
                try stdout.writeAll(entry.path);
                try stdout.writeAll("\n");
            }
            if (show_deleted and !file_exists) {
                try stdout.writeAll(entry.path);
                try stdout.writeAll("\n");
            }
            if (show_modified and file_exists) {
                const content = cwd.readFileAlloc(allocator, entry.path, 100 * 1024 * 1024) catch continue;
                defer allocator.free(content);

                const blob = object.Blob.init(content);
                const current_sha = blob.computeHash();

                if (!std.mem.eql(u8, &current_sha, &entry.sha)) {
                    try stdout.writeAll(entry.path);
                    try stdout.writeAll("\n");
                }
            }
        }

        if (show_others) {
            var dir = cwd.openDir(".", .{ .iterate = true }) catch return;
            defer dir.close();

            var iter = dir.iterate();
            while (try iter.next()) |file_entry| {
                if (file_entry.kind != .file) continue;
                if (std.mem.startsWith(u8, file_entry.name, ".")) continue;

                var in_index = false;
                for (idx.entries) |idx_entry| {
                    if (std.mem.eql(u8, idx_entry.path, file_entry.name)) {
                        in_index = true;
                        break;
                    }
                }

                if (!in_index) {
                    try stdout.writeAll(file_entry.name);
                    try stdout.writeAll("\n");
                }
            }
        }
    }
}

test "ls-files basic" {
    // Would need temp repo
}
