// forge commit-tree - create commit object from tree

const std = @import("std");
const object = @import("../object/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var tree_sha: ?object.Sha1 = null;
    var parents: std.ArrayList(object.Sha1) = .empty;
    defer parents.deinit(allocator);
    var message: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-p") and i + 1 < args.len) {
            i += 1;
            const parent_hex = args[i];
            if (parent_hex.len != 40) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: invalid parent sha '{s}'\n", .{parent_hex}) catch "fatal: invalid sha\n";
                try stderr.writeAll(msg);
                return;
            }
            const parent_sha = object.hash.fromHex(parent_hex[0..40]) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: invalid parent sha '{s}'\n", .{parent_hex}) catch "fatal: invalid sha\n";
                try stderr.writeAll(msg);
                return;
            };
            try parents.append(allocator, parent_sha);
        } else if (std.mem.eql(u8, arg, "-m") and i + 1 < args.len) {
            i += 1;
            message = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-") and tree_sha == null) {
            if (arg.len != 40) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: invalid tree sha '{s}'\n", .{arg}) catch "fatal: invalid sha\n";
                try stderr.writeAll(msg);
                return;
            }
            tree_sha = object.hash.fromHex(arg[0..40]) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: invalid tree sha '{s}'\n", .{arg}) catch "fatal: invalid sha\n";
                try stderr.writeAll(msg);
                return;
            };
        }
    }

    if (tree_sha == null) {
        try stderr.writeAll("usage: forge commit-tree <tree> [-p <parent>]... -m <message>\n");
        return;
    }

    if (message == null) {
        try stderr.writeAll("error: -m <message> is required\n");
        return;
    }

    var store = object.ObjectStore.init(allocator, ".git");

    // Verify tree exists
    if (!store.exists(tree_sha.?)) {
        try stderr.writeAll("fatal: not a valid tree object\n");
        return;
    }

    // Get author/committer from environment or use default
    const author = std.posix.getenv("GIT_AUTHOR_NAME") orelse "Forge User";
    const email = std.posix.getenv("GIT_AUTHOR_EMAIL") orelse "forge@example.com";
    const timestamp = std.time.timestamp();

    // Build commit content
    var commit_data: std.ArrayList(u8) = .empty;
    defer commit_data.deinit(allocator);

    // tree line
    try commit_data.appendSlice(allocator, "tree ");
    const tree_hex = object.hash.toHex(tree_sha.?);
    try commit_data.appendSlice(allocator, &tree_hex);
    try commit_data.append(allocator, '\n');

    // parent lines
    for (parents.items) |parent| {
        try commit_data.appendSlice(allocator, "parent ");
        const parent_hex = object.hash.toHex(parent);
        try commit_data.appendSlice(allocator, &parent_hex);
        try commit_data.append(allocator, '\n');
    }

    // author line
    var author_buf: [256]u8 = undefined;
    const author_line = std.fmt.bufPrint(&author_buf, "author {s} <{s}> {d} +0000\n", .{ author, email, timestamp }) catch return;
    try commit_data.appendSlice(allocator, author_line);

    // committer line
    var committer_buf: [256]u8 = undefined;
    const committer_line = std.fmt.bufPrint(&committer_buf, "committer {s} <{s}> {d} +0000\n", .{ author, email, timestamp }) catch return;
    try commit_data.appendSlice(allocator, committer_line);

    // message
    try commit_data.append(allocator, '\n');
    try commit_data.appendSlice(allocator, message.?);
    try commit_data.append(allocator, '\n');

    // Write commit
    const commit_sha = try store.write(.commit, commit_data.items);
    const hex = object.hash.toHex(commit_sha);
    try stdout.writeAll(&hex);
    try stdout.writeAll("\n");
}

test "commit-tree basic" {
    // Would need temp repo with tree object
}
