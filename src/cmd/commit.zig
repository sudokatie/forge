// forge commit - create a commit from staged changes

const std = @import("std");
const object = @import("../object/mod.zig");
const index_mod = @import("../index/mod.zig");
const refs = @import("../refs/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    // Parse -m message flag
    var message: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
            message = args[i + 1];
            i += 1;
        }
    }

    if (message == null) {
        try stderr.writeAll("error: switch `m' requires a value\n");
        return;
    }

    // Read index
    var idx = try index_mod.Index.read(allocator, ".git");
    defer idx.deinit();

    if (idx.entries.len == 0) {
        try stderr.writeAll("nothing to commit (create/copy files and use \"forge add\" to track)\n");
        return;
    }

    var store = object.ObjectStore.init(allocator, ".git");

    // Build tree from index
    const tree_sha = try buildTree(allocator, &store, idx.entries);

    // Get parent commit (if any)
    var ref_store = refs.RefStore.init(allocator, ".git");
    const parent = ref_store.readHead() catch |err| blk: {
        if (err == error.HeadNotFound) break :blk null else return err;
    };

    var parent_sha: ?object.Sha1 = null;
    if (parent) |p| {
        switch (p) {
            .symbolic => |sym| {
                parent_sha = ref_store.resolve(sym) catch null;
            },
            .direct => |sha| {
                parent_sha = sha;
            },
        }
    }

    // Build commit object
    const timestamp = std.time.timestamp();
    const author = "Forge User <forge@example.com>";

    var commit_data: std.ArrayList(u8) = .empty;
    defer commit_data.deinit(allocator);

    const writer = commit_data.writer(allocator);
    try writer.print("tree {s}\n", .{object.hash.toHex(tree_sha)});

    if (parent_sha) |psha| {
        try writer.print("parent {s}\n", .{object.hash.toHex(psha)});
    }

    try writer.print("author {s} {d} +0000\n", .{ author, timestamp });
    try writer.print("committer {s} {d} +0000\n", .{ author, timestamp });
    try writer.print("\n{s}\n", .{message.?});

    // Write commit object
    const commit_sha = try store.write(.commit, commit_data.items);

    // Update HEAD
    const head = ref_store.readHead() catch null;
    if (head) |h| {
        switch (h) {
            .symbolic => |sym| {
                try ref_store.update(sym, commit_sha);
            },
            .direct => {
                // Detached HEAD - update HEAD directly
                const cwd = std.fs.cwd();
                const head_file = try cwd.createFile(".git/HEAD", .{});
                defer head_file.close();
                var hex_buf: [41]u8 = undefined;
                const hex = object.hash.toHex(commit_sha);
                @memcpy(hex_buf[0..40], &hex);
                hex_buf[40] = '\n';
                try head_file.writeAll(&hex_buf);
            },
        }
    } else {
        // First commit - create refs/heads/main
        try ref_store.update("refs/heads/main", commit_sha);
    }

    // Print result
    const short_sha = object.hash.toHex(commit_sha)[0..7];
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[main {s}] {s}\n", .{ short_sha, message.? }) catch {
        try stdout.writeAll("Commit created\n");
        return;
    };
    try stdout.writeAll(msg);
}

/// Build a tree object from index entries
fn buildTree(allocator: std.mem.Allocator, store: *object.ObjectStore, entries: []const index_mod.IndexEntry) !object.Sha1 {
    var tree_data: std.ArrayList(u8) = .empty;
    defer tree_data.deinit(allocator);

    // Simple flat tree for now (no subdirectories)
    for (entries) |entry| {
        // Mode + space + name + null + sha
        try tree_data.writer(allocator).print("{o} {s}\x00", .{ entry.mode, entry.path });
        try tree_data.appendSlice(allocator, &entry.sha);
    }

    return try store.write(.tree, tree_data.items);
}

test "commit basic" {
    // Would need temp directory with git init + staged files
}
