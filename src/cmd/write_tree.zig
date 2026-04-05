// forge write-tree - create tree object from index

const std = @import("std");
const object = @import("../object/mod.zig");
const index_mod = @import("../index/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var idx = try index_mod.Index.read(allocator, ".git");
    defer idx.deinit();

    if (idx.entries.len == 0) {
        try stderr.writeAll("error: no files in index\n");
        return;
    }

    var store = object.ObjectStore.init(allocator, ".git");

    // Build tree from index (handles nested directories)
    const tree_sha = try buildTreeFromIndex(allocator, &store, idx.entries, "");

    const hex = object.hash.toHex(tree_sha);
    try stdout.writeAll(&hex);
    try stdout.writeAll("\n");
}

/// Build tree object from index entries, handling nested directories
fn buildTreeFromIndex(
    allocator: std.mem.Allocator,
    store: *object.ObjectStore,
    entries: []const index_mod.IndexEntry,
    prefix: []const u8,
) !object.Sha1 {
    var tree_entries: std.ArrayList(TreeBuildEntry) = .empty;
    defer {
        for (tree_entries.items) |e| {
            allocator.free(e.name);
        }
        tree_entries.deinit(allocator);
    }

    // Group entries by first path component
    var processed = std.StringHashMap(void).init(allocator);
    defer processed.deinit();

    for (entries) |entry| {
        // Get relative path from prefix
        const rel_path = if (prefix.len > 0) blk: {
            if (std.mem.startsWith(u8, entry.path, prefix)) {
                const after_prefix = entry.path[prefix.len..];
                if (after_prefix.len > 0 and after_prefix[0] == '/') {
                    break :blk after_prefix[1..];
                }
            }
            continue;
        } else entry.path;

        // Get first component
        const slash_pos = std.mem.indexOf(u8, rel_path, "/");
        const first_component = if (slash_pos) |pos| rel_path[0..pos] else rel_path;

        // Skip if already processed
        if (processed.contains(first_component)) continue;
        try processed.put(first_component, {});

        if (slash_pos != null) {
            // This is a directory - recursively build subtree
            const dir_prefix = if (prefix.len > 0)
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, first_component })
            else
                try allocator.dupe(u8, first_component);
            defer allocator.free(dir_prefix);

            const subtree_sha = try buildTreeFromIndex(allocator, store, entries, dir_prefix);

            try tree_entries.append(allocator, .{
                .mode = 0o40000, // Directory
                .name = try allocator.dupe(u8, first_component),
                .sha = subtree_sha,
            });
        } else {
            // This is a file
            try tree_entries.append(allocator, .{
                .mode = entry.mode,
                .name = try allocator.dupe(u8, first_component),
                .sha = entry.sha,
            });
        }
    }

    // Sort entries by name (Git requirement)
    std.mem.sort(TreeBuildEntry, tree_entries.items, {}, struct {
        fn lessThan(_: void, a: TreeBuildEntry, b: TreeBuildEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    // Serialize tree
    var tree_data: std.ArrayList(u8) = .empty;
    defer tree_data.deinit(allocator);

    for (tree_entries.items) |entry| {
        var mode_buf: [16]u8 = undefined;
        const mode_str = std.fmt.bufPrint(&mode_buf, "{o} ", .{entry.mode}) catch continue;
        try tree_data.appendSlice(allocator, mode_str);
        try tree_data.appendSlice(allocator, entry.name);
        try tree_data.append(allocator, 0);
        try tree_data.appendSlice(allocator, &entry.sha);
    }

    return try store.write(.tree, tree_data.items);
}

const TreeBuildEntry = struct {
    mode: u32,
    name: []const u8,
    sha: object.Sha1,
};

test "write-tree basic" {
    // Would need temp repo with staged files
}
