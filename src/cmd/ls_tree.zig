// forge ls-tree - list tree contents

const std = @import("std");
const object = @import("../object/mod.zig");
const refs = @import("../refs/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var recursive = false;
    var name_only = false;
    var tree_ref: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            tree_ref = arg;
        }
    }

    if (tree_ref == null) {
        try stderr.writeAll("usage: forge ls-tree [-r] [--name-only] <tree-ish>\n");
        return;
    }

    var store = object.ObjectStore.init(allocator, ".git");

    // Resolve tree-ish to SHA
    const sha = try resolveTreeish(allocator, tree_ref.?, &store);

    // Get the tree (might need to dereference commit first)
    const tree_sha = try getTreeSha(sha, &store);

    try listTree(allocator, &store, tree_sha, "", recursive, name_only, stdout);
}

fn resolveTreeish(allocator: std.mem.Allocator, ref: []const u8, store: *object.ObjectStore) !object.Sha1 {
    _ = store;

    // Try as SHA first
    if (ref.len == 40) {
        if (object.hash.fromHex(ref[0..40])) |sha| {
            return sha;
        } else |_| {}
    }

    // Try as ref name
    var ref_store = refs.RefStore.init(allocator, ".git");

    // HEAD
    if (std.mem.eql(u8, ref, "HEAD")) {
        const head = try ref_store.readHead();
        return switch (head) {
            .direct => |s| s,
            .symbolic => |sym| blk: {
                defer allocator.free(sym);
                break :blk try ref_store.resolve(sym);
            },
        };
    }

    // Branch name
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
    defer allocator.free(branch_ref);

    return ref_store.resolve(branch_ref) catch {
        return error.InvalidTreeish;
    };
}

fn getTreeSha(sha: object.Sha1, store: *object.ObjectStore) !object.Sha1 {
    const stat = store.statObject(sha) catch return sha;

    if (stat.obj_type == .tree) {
        return sha;
    } else if (stat.obj_type == .commit) {
        const obj = try store.read(sha);
        return obj.commit.tree;
    }

    return error.NotATree;
}

fn listTree(
    allocator: std.mem.Allocator,
    store: *object.ObjectStore,
    tree_sha: object.Sha1,
    prefix: []const u8,
    recursive: bool,
    name_only: bool,
    stdout: std.fs.File,
) !void {
    const obj = try store.read(tree_sha);
    if (obj != .tree) return error.NotATree;

    const tree = obj.tree;
    defer {
        var t = tree;
        t.deinit();
    }

    for (tree.entries) |entry| {
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(full_path);

        const is_tree = entry.mode == 0o40000;
        const type_str = if (is_tree) "tree" else "blob";
        const hex = object.hash.toHex(entry.sha);

        if (name_only) {
            try stdout.writeAll(full_path);
            try stdout.writeAll("\n");
        } else {
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{o:0>6} {s} {s}\t{s}\n", .{ entry.mode, type_str, hex, full_path }) catch continue;
            try stdout.writeAll(line);
        }

        if (recursive and is_tree) {
            try listTree(allocator, store, entry.sha, full_path, recursive, name_only, stdout);
        }
    }
}

test "ls-tree basic" {
    // Would need temp repo with tree
}
