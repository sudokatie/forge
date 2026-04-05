// forge status - show working tree status

const std = @import("std");
const object = @import("../object/mod.zig");
const index_mod = @import("../index/mod.zig");
const refs = @import("../refs/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    // Get branch name
    var ref_store = refs.RefStore.init(allocator, ".git");
    const head = ref_store.readHead() catch {
        try stdout.writeAll("On branch main\n\n");
        try stdout.writeAll("No commits yet\n\n");
        return;
    };

    switch (head) {
        .symbolic => |sym| {
            defer allocator.free(sym);
            const branch = if (std.mem.startsWith(u8, sym, "refs/heads/"))
                sym[11..]
            else
                sym;
            try stdout.writeAll("On branch ");
            try stdout.writeAll(branch);
            try stdout.writeAll("\n\n");
        },
        .direct => |sha| {
            const hex = object.hash.toHex(sha);
            try stdout.writeAll("HEAD detached at ");
            try stdout.writeAll(hex[0..7]);
            try stdout.writeAll("\n\n");
        },
    }

    var idx = try index_mod.Index.read(allocator, ".git");
    defer idx.deinit();

    var store = object.ObjectStore.init(allocator, ".git");
    const cwd = std.fs.cwd();

    // Get HEAD tree for comparison
    const head_tree = getHeadTree(allocator, &ref_store, &store) catch null;
    var head_files = std.StringHashMap(object.Sha1).init(allocator);
    defer head_files.deinit();

    if (head_tree) |tree_sha| {
        try collectTreeFiles(allocator, &store, tree_sha, "", &head_files);
    }

    // Categorize changes
    var staged_new: std.ArrayList([]const u8) = .empty;
    defer staged_new.deinit(allocator);
    var staged_modified: std.ArrayList([]const u8) = .empty;
    defer staged_modified.deinit(allocator);
    var staged_deleted: std.ArrayList([]const u8) = .empty;
    defer staged_deleted.deinit(allocator);

    var unstaged_modified: std.ArrayList([]const u8) = .empty;
    defer unstaged_modified.deinit(allocator);
    var unstaged_deleted: std.ArrayList([]const u8) = .empty;
    defer unstaged_deleted.deinit(allocator);

    var untracked: std.ArrayList([]const u8) = .empty;
    defer {
        for (untracked.items) |p| allocator.free(p);
        untracked.deinit(allocator);
    }

    // Check staged changes (index vs HEAD)
    for (idx.entries) |entry| {
        if (head_files.get(entry.path)) |head_sha| {
            if (!std.mem.eql(u8, &head_sha, &entry.sha)) {
                try staged_modified.append(allocator, entry.path);
            }
        } else {
            try staged_new.append(allocator, entry.path);
        }
    }

    // Check for staged deletions (in HEAD but not in index)
    var head_iter = head_files.iterator();
    while (head_iter.next()) |kv| {
        var in_index = false;
        for (idx.entries) |entry| {
            if (std.mem.eql(u8, entry.path, kv.key_ptr.*)) {
                in_index = true;
                break;
            }
        }
        if (!in_index) {
            try staged_deleted.append(allocator, kv.key_ptr.*);
        }
    }

    // Check unstaged changes (working tree vs index)
    for (idx.entries) |entry| {
        const file_exists = cwd.access(entry.path, .{}) != error.FileNotFound;

        if (!file_exists) {
            try unstaged_deleted.append(allocator, entry.path);
        } else {
            // Check if content modified
            const content = cwd.readFileAlloc(allocator, entry.path, 100 * 1024 * 1024) catch continue;
            defer allocator.free(content);

            const blob = object.Blob.init(content);
            const current_sha = blob.computeHash();

            if (!std.mem.eql(u8, &current_sha, &entry.sha)) {
                try unstaged_modified.append(allocator, entry.path);
            }
        }
    }

    // Find untracked files
    try findUntracked(allocator, &idx, ".", &untracked);

    // Print output
    const has_staged = staged_new.items.len > 0 or staged_modified.items.len > 0 or staged_deleted.items.len > 0;
    const has_unstaged = unstaged_modified.items.len > 0 or unstaged_deleted.items.len > 0;

    if (has_staged) {
        try stdout.writeAll("Changes to be committed:\n");
        try stdout.writeAll("  (use \"forge restore --staged <file>...\" to unstage)\n\n");

        for (staged_new.items) |path| {
            try stdout.writeAll("\tnew file:   ");
            try stdout.writeAll(path);
            try stdout.writeAll("\n");
        }
        for (staged_modified.items) |path| {
            try stdout.writeAll("\tmodified:   ");
            try stdout.writeAll(path);
            try stdout.writeAll("\n");
        }
        for (staged_deleted.items) |path| {
            try stdout.writeAll("\tdeleted:    ");
            try stdout.writeAll(path);
            try stdout.writeAll("\n");
        }
        try stdout.writeAll("\n");
    }

    if (has_unstaged) {
        try stdout.writeAll("Changes not staged for commit:\n");
        try stdout.writeAll("  (use \"forge add <file>...\" to update what will be committed)\n\n");

        for (unstaged_modified.items) |path| {
            try stdout.writeAll("\tmodified:   ");
            try stdout.writeAll(path);
            try stdout.writeAll("\n");
        }
        for (unstaged_deleted.items) |path| {
            try stdout.writeAll("\tdeleted:    ");
            try stdout.writeAll(path);
            try stdout.writeAll("\n");
        }
        try stdout.writeAll("\n");
    }

    if (untracked.items.len > 0) {
        try stdout.writeAll("Untracked files:\n");
        try stdout.writeAll("  (use \"forge add <file>...\" to include in what will be committed)\n\n");

        for (untracked.items) |path| {
            try stdout.writeAll("\t");
            try stdout.writeAll(path);
            try stdout.writeAll("\n");
        }
        try stdout.writeAll("\n");
    }

    if (!has_staged and !has_unstaged and untracked.items.len == 0) {
        try stdout.writeAll("nothing to commit, working tree clean\n");
    }
}

fn getHeadTree(allocator: std.mem.Allocator, ref_store: *refs.RefStore, store: *object.ObjectStore) !object.Sha1 {
    const head = try ref_store.readHead();
    const head_sha = switch (head) {
        .direct => |s| s,
        .symbolic => |sym| blk: {
            defer allocator.free(sym);
            break :blk try ref_store.resolve(sym);
        },
    };

    const obj = try store.read(head_sha);
    if (obj != .commit) return error.NotACommit;
    return obj.commit.tree;
}

fn collectTreeFiles(
    allocator: std.mem.Allocator,
    store: *object.ObjectStore,
    tree_sha: object.Sha1,
    prefix: []const u8,
    files: *std.StringHashMap(object.Sha1),
) !void {
    const obj = try store.read(tree_sha);
    if (obj != .tree) return;

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

        if (entry.mode == 0o40000) {
            // Directory - recurse
            defer allocator.free(full_path);
            try collectTreeFiles(allocator, store, entry.sha, full_path, files);
        } else {
            // File
            try files.put(full_path, entry.sha);
        }
    }
}

fn findUntracked(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    dir_path: []const u8,
    untracked: *std.ArrayList([]const u8),
) !void {
    const cwd = std.fs.cwd();
    var dir = cwd.openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden files and .git
        if (std.mem.startsWith(u8, entry.name, ".")) continue;

        const full_path = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });

        if (entry.kind == .directory) {
            defer allocator.free(full_path);
            try findUntracked(allocator, idx, full_path, untracked);
        } else if (entry.kind == .file) {
            var in_index = false;
            for (idx.entries) |idx_entry| {
                if (std.mem.eql(u8, idx_entry.path, full_path)) {
                    in_index = true;
                    break;
                }
            }

            if (!in_index) {
                try untracked.append(allocator, full_path);
            } else {
                allocator.free(full_path);
            }
        } else {
            allocator.free(full_path);
        }
    }
}

test "status basic" {
    // Would need temp repo
}
