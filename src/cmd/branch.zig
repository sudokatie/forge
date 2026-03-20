// forge branch - list, create, or delete branches

const std = @import("std");
const object = @import("../object/mod.zig");
const refs = @import("../refs/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var ref_store = refs.RefStore.init(allocator, ".git");

    // Parse flags
    var delete = false;
    var branch_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "-D")) {
            delete = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            branch_name = arg;
        }
    }

    if (delete and branch_name != null) {
        // Delete branch
        const ref_path = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name.?});
        defer allocator.free(ref_path);

        const full_path = try std.fmt.allocPrint(allocator, ".git/{s}", .{ref_path});
        defer allocator.free(full_path);

        std.fs.cwd().deleteFile(full_path) catch |err| {
            if (err == error.FileNotFound) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: branch '{s}' not found.\n", .{branch_name.?}) catch {
                    try stderr.writeAll("error: branch not found\n");
                    return;
                };
                try stderr.writeAll(msg);
                return;
            }
            return err;
        };

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Deleted branch {s}\n", .{branch_name.?}) catch {
            try stdout.writeAll("Deleted branch\n");
            return;
        };
        try stdout.writeAll(msg);
        return;
    }

    if (branch_name) |name| {
        // Create new branch
        const head = ref_store.readHead() catch {
            try stderr.writeAll("fatal: Not a valid object name: 'HEAD'\n");
            return;
        };

        const sha = switch (head) {
            .direct => |s| s,
            .symbolic => |sym| blk: {
                defer allocator.free(sym);
                break :blk ref_store.resolve(sym) catch {
                    try stderr.writeAll("fatal: Not a valid object name: 'HEAD'\n");
                    return;
                };
            },
        };

        const ref_path = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
        defer allocator.free(ref_path);

        try ref_store.update(ref_path, sha);

        return;
    }

    // List branches
    const head = ref_store.readHead() catch null;
    var current_branch: ?[]const u8 = null;
    if (head) |h| {
        switch (h) {
            .symbolic => |sym| {
                if (std.mem.startsWith(u8, sym, "refs/heads/")) {
                    current_branch = sym[11..];
                }
            },
            .direct => {},
        }
    }

    // List refs/heads
    const cwd = std.fs.cwd();
    var dir = cwd.openDir(".git/refs/heads", .{ .iterate = true }) catch {
        // No branches yet
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const is_current = if (current_branch) |cb| std.mem.eql(u8, cb, entry.name) else false;

        if (is_current) {
            try stdout.writeAll("* ");
        } else {
            try stdout.writeAll("  ");
        }
        try stdout.writeAll(entry.name);
        try stdout.writeAll("\n");
    }

    if (head) |h| {
        switch (h) {
            .symbolic => |sym| allocator.free(sym),
            .direct => {},
        }
    }
}

test "branch basic" {
    // Would need temp repo
}
