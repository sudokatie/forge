// forge checkout - switch branches or restore working tree files

const std = @import("std");
const object = @import("../object/mod.zig");
const refs = @import("../refs/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    // Parse flags
    var create_branch = false;
    var target: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-b")) {
            create_branch = true;
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            target = args[i];
        }
    }

    if (target == null) {
        try stderr.writeAll("error: switch `b' requires a value\n");
        return;
    }

    var ref_store = refs.RefStore.init(allocator, ".git");
    const cwd = std.fs.cwd();

    if (create_branch) {
        // Create new branch and switch to it
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

        // Create new branch ref
        const ref_path = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{target.?});
        defer allocator.free(ref_path);
        try ref_store.update(ref_path, sha);

        // Update HEAD to point to new branch
        const head_file = try cwd.createFile(".git/HEAD", .{});
        defer head_file.close();
        try head_file.writer().print("ref: refs/heads/{s}\n", .{target.?});

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Switched to a new branch '{s}'\n", .{target.?}) catch {
            try stdout.writeAll("Switched to new branch\n");
            return;
        };
        try stdout.writeAll(msg);
        return;
    }

    // Try to switch to existing branch
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{target.?});
    defer allocator.free(branch_ref);

    // Check if branch exists
    const branch_path = try std.fmt.allocPrint(allocator, ".git/{s}", .{branch_ref});
    defer allocator.free(branch_path);

    cwd.access(branch_path, .{}) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: pathspec '{s}' did not match any file(s) known to forge.\n", .{target.?}) catch {
            try stderr.writeAll("error: branch not found\n");
            return;
        };
        try stderr.writeAll(msg);
        return;
    };

    // Update HEAD to point to branch
    const head_file = try cwd.createFile(".git/HEAD", .{});
    defer head_file.close();
    try head_file.writer().print("ref: {s}\n", .{branch_ref});

    // TODO: Update working tree from branch's commit tree

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Switched to branch '{s}'\n", .{target.?}) catch {
        try stdout.writeAll("Switched to branch\n");
        return;
    };
    try stdout.writeAll(msg);
}

test "checkout basic" {
    // Would need temp repo
}
