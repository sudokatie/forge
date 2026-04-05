// forge diff - show changes between commits, index, and working tree

const std = @import("std");
const object = @import("../object/mod.zig");
const index_mod = @import("../index/mod.zig");
const refs = @import("../refs/mod.zig");
const myers = @import("../diff/myers.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    var cached = false;
    var specific_file: ?[]const u8 = null;
    var commit1: ?[]const u8 = null;
    var commit2: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "--staged")) {
            cached = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            // Skip separator
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Check for commit range (commit1..commit2)
            if (std.mem.indexOf(u8, arg, "..")) |dot_pos| {
                commit1 = arg[0..dot_pos];
                commit2 = arg[dot_pos + 2 ..];
            } else if (commit1 == null and !cached) {
                // Could be a commit ref or a file
                // Try to resolve as ref first
                if (isValidRef(allocator, arg)) {
                    commit1 = arg;
                } else {
                    specific_file = arg;
                }
            } else if (commit2 == null and commit1 != null) {
                commit2 = arg;
            } else {
                specific_file = arg;
            }
        }
    }

    var idx = try index_mod.Index.read(allocator, ".git");
    defer idx.deinit();

    var store = object.ObjectStore.init(allocator, ".git");
    var ref_store = refs.RefStore.init(allocator, ".git");
    const cwd = std.fs.cwd();

    // Commit range diff: diff <commit1>..<commit2>
    if (commit1 != null and commit2 != null) {
        const sha1 = try resolveRef(allocator, &ref_store, &store, commit1.?);
        const sha2 = try resolveRef(allocator, &ref_store, &store, commit2.?);

        const tree1 = try getTreeFromCommit(allocator, &store, sha1);
        const tree2 = try getTreeFromCommit(allocator, &store, sha2);

        try diffTrees(allocator, &store, tree1, tree2, "", specific_file, stdout);
        return;
    }

    // Single commit diff: diff <commit> (compare commit to working tree or index)
    if (commit1 != null and !cached) {
        const sha = try resolveRef(allocator, &ref_store, &store, commit1.?);
        const commit_tree = try getTreeFromCommit(allocator, &store, sha);

        // Compare commit tree to working tree
        try diffTreeToWorkingTree(allocator, &store, commit_tree, "", specific_file, stdout, cwd);
        return;
    }

    if (cached) {
        // Diff index vs HEAD (staged changes)
        const head_tree = getHeadTree(allocator, &ref_store, &store) catch null;

        for (idx.entries) |entry| {
            if (specific_file != null and !std.mem.eql(u8, entry.path, specific_file.?)) {
                continue;
            }

            const old_content = if (head_tree) |tree_sha|
                getBlobFromTree(allocator, &store, tree_sha, entry.path) catch null
            else
                null;
            defer if (old_content) |c| allocator.free(c);

            const new_content = getBlob(allocator, &store, entry.sha) catch null;
            defer if (new_content) |c| allocator.free(c);

            const old = old_content orelse "";
            const new = new_content orelse "";

            if (!std.mem.eql(u8, old, new)) {
                const old_name = try std.fmt.allocPrint(allocator, "a/{s}", .{entry.path});
                defer allocator.free(old_name);
                const new_name = try std.fmt.allocPrint(allocator, "b/{s}", .{entry.path});
                defer allocator.free(new_name);

                const diff_output = try myers.unifiedDiff(allocator, old_name, new_name, old, new);
                defer allocator.free(diff_output);
                try stdout.writeAll(diff_output);
            }
        }
    } else {
        // Diff working tree vs index (unstaged changes)
        for (idx.entries) |entry| {
            if (specific_file != null and !std.mem.eql(u8, entry.path, specific_file.?)) {
                continue;
            }

            const work_content = cwd.readFileAlloc(allocator, entry.path, 100 * 1024 * 1024) catch null;
            defer if (work_content) |c| allocator.free(c);

            const index_content = getBlob(allocator, &store, entry.sha) catch null;
            defer if (index_content) |c| allocator.free(c);

            const old = index_content orelse "";
            const new = work_content orelse "";

            if (!std.mem.eql(u8, old, new)) {
                const old_name = try std.fmt.allocPrint(allocator, "a/{s}", .{entry.path});
                defer allocator.free(old_name);
                const new_name = try std.fmt.allocPrint(allocator, "b/{s}", .{entry.path});
                defer allocator.free(new_name);

                const diff_output = try myers.unifiedDiff(allocator, old_name, new_name, old, new);
                defer allocator.free(diff_output);
                try stdout.writeAll(diff_output);
            }
        }
    }
}

fn isValidRef(allocator: std.mem.Allocator, ref: []const u8) bool {
    var ref_store = refs.RefStore.init(allocator, ".git");

    // Try HEAD
    if (std.mem.eql(u8, ref, "HEAD")) {
        return true;
    }

    // Try as branch
    const branch_ref = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref}) catch return false;
    defer allocator.free(branch_ref);
    if (ref_store.resolve(branch_ref)) |_| {
        return true;
    } else |_| {}

    // Try as tag
    const tag_ref = std.fmt.allocPrint(allocator, "refs/tags/{s}", .{ref}) catch return false;
    defer allocator.free(tag_ref);
    if (ref_store.resolve(tag_ref)) |_| {
        return true;
    } else |_| {}

    // Try as full SHA
    if (ref.len == 40) {
        if (object.hash.fromHex(ref[0..40])) |_| {
            return true;
        } else |_| {}
    }

    return false;
}

fn resolveRef(allocator: std.mem.Allocator, ref_store: *refs.RefStore, store: *object.ObjectStore, ref: []const u8) !object.Sha1 {
    _ = store;

    // Try HEAD
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

    // Try as branch
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
    defer allocator.free(branch_ref);
    if (ref_store.resolve(branch_ref)) |sha| {
        return sha;
    } else |_| {}

    // Try as tag
    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{ref});
    defer allocator.free(tag_ref);
    if (ref_store.resolve(tag_ref)) |sha| {
        return sha;
    } else |_| {}

    // Try as direct SHA
    if (ref.len == 40) {
        return try object.hash.fromHex(ref[0..40]);
    }

    return error.InvalidRef;
}

fn getTreeFromCommit(allocator: std.mem.Allocator, store: *object.ObjectStore, commit_sha: object.Sha1) !object.Sha1 {
    _ = allocator;
    const obj = try store.read(commit_sha);
    if (obj != .commit) return error.NotACommit;
    return obj.commit.tree;
}

fn diffTrees(
    allocator: std.mem.Allocator,
    store: *object.ObjectStore,
    tree1: object.Sha1,
    tree2: object.Sha1,
    prefix: []const u8,
    specific_file: ?[]const u8,
    stdout: std.fs.File,
) !void {
    // Collect files from both trees
    var files1 = std.StringHashMap(object.Sha1).init(allocator);
    defer {
        var iter = files1.keyIterator();
        while (iter.next()) |k| allocator.free(k.*);
        files1.deinit();
    }

    var files2 = std.StringHashMap(object.Sha1).init(allocator);
    defer {
        var iter = files2.keyIterator();
        while (iter.next()) |k| allocator.free(k.*);
        files2.deinit();
    }

    try collectTreeFiles(allocator, store, tree1, prefix, &files1);
    try collectTreeFiles(allocator, store, tree2, prefix, &files2);

    // Find modified and deleted files
    var iter1 = files1.iterator();
    while (iter1.next()) |kv| {
        const path = kv.key_ptr.*;
        const sha1 = kv.value_ptr.*;

        if (specific_file != null and !std.mem.eql(u8, path, specific_file.?)) {
            continue;
        }

        const sha2 = files2.get(path);

        if (sha2 == null) {
            // Deleted
            const old_content = getBlob(allocator, store, sha1) catch "";
            defer if (old_content.len > 0) allocator.free(old_content);

            const old_name = try std.fmt.allocPrint(allocator, "a/{s}", .{path});
            defer allocator.free(old_name);
            const new_name = try std.fmt.allocPrint(allocator, "b/{s}", .{path});
            defer allocator.free(new_name);

            const diff_output = try myers.unifiedDiff(allocator, old_name, new_name, old_content, "");
            defer allocator.free(diff_output);
            try stdout.writeAll(diff_output);
        } else if (!std.mem.eql(u8, &sha1, &sha2.?)) {
            // Modified
            const old_content = getBlob(allocator, store, sha1) catch "";
            defer if (old_content.len > 0) allocator.free(old_content);

            const new_content = getBlob(allocator, store, sha2.?) catch "";
            defer if (new_content.len > 0) allocator.free(new_content);

            const old_name = try std.fmt.allocPrint(allocator, "a/{s}", .{path});
            defer allocator.free(old_name);
            const new_name = try std.fmt.allocPrint(allocator, "b/{s}", .{path});
            defer allocator.free(new_name);

            const diff_output = try myers.unifiedDiff(allocator, old_name, new_name, old_content, new_content);
            defer allocator.free(diff_output);
            try stdout.writeAll(diff_output);
        }
    }

    // Find added files
    var iter2 = files2.iterator();
    while (iter2.next()) |kv| {
        const path = kv.key_ptr.*;
        const sha2 = kv.value_ptr.*;

        if (specific_file != null and !std.mem.eql(u8, path, specific_file.?)) {
            continue;
        }

        if (files1.get(path) == null) {
            // Added
            const new_content = getBlob(allocator, store, sha2) catch "";
            defer if (new_content.len > 0) allocator.free(new_content);

            const old_name = try std.fmt.allocPrint(allocator, "a/{s}", .{path});
            defer allocator.free(old_name);
            const new_name = try std.fmt.allocPrint(allocator, "b/{s}", .{path});
            defer allocator.free(new_name);

            const diff_output = try myers.unifiedDiff(allocator, old_name, new_name, "", new_content);
            defer allocator.free(diff_output);
            try stdout.writeAll(diff_output);
        }
    }
}

fn diffTreeToWorkingTree(
    allocator: std.mem.Allocator,
    store: *object.ObjectStore,
    tree_sha: object.Sha1,
    prefix: []const u8,
    specific_file: ?[]const u8,
    stdout: std.fs.File,
    cwd: std.fs.Dir,
) !void {
    var tree_files = std.StringHashMap(object.Sha1).init(allocator);
    defer {
        var iter = tree_files.keyIterator();
        while (iter.next()) |k| allocator.free(k.*);
        tree_files.deinit();
    }

    try collectTreeFiles(allocator, store, tree_sha, prefix, &tree_files);

    var iter = tree_files.iterator();
    while (iter.next()) |kv| {
        const path = kv.key_ptr.*;
        const tree_sha_entry = kv.value_ptr.*;

        if (specific_file != null and !std.mem.eql(u8, path, specific_file.?)) {
            continue;
        }

        const tree_content = getBlob(allocator, store, tree_sha_entry) catch "";
        defer if (tree_content.len > 0) allocator.free(tree_content);

        const work_content = cwd.readFileAlloc(allocator, path, 100 * 1024 * 1024) catch "";
        defer if (work_content.len > 0) allocator.free(work_content);

        if (!std.mem.eql(u8, tree_content, work_content)) {
            const old_name = try std.fmt.allocPrint(allocator, "a/{s}", .{path});
            defer allocator.free(old_name);
            const new_name = try std.fmt.allocPrint(allocator, "b/{s}", .{path});
            defer allocator.free(new_name);

            const diff_output = try myers.unifiedDiff(allocator, old_name, new_name, tree_content, work_content);
            defer allocator.free(diff_output);
            try stdout.writeAll(diff_output);
        }
    }
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
            defer allocator.free(full_path);
            try collectTreeFiles(allocator, store, entry.sha, full_path, files);
        } else {
            try files.put(full_path, entry.sha);
        }
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

fn getBlobFromTree(allocator: std.mem.Allocator, store: *object.ObjectStore, tree_sha: object.Sha1, path: []const u8) ![]u8 {
    const slash_pos = std.mem.indexOf(u8, path, "/");

    const obj = try store.read(tree_sha);
    if (obj != .tree) return error.NotATree;

    const tree = obj.tree;
    defer {
        var t = tree;
        t.deinit();
    }

    const first_component = if (slash_pos) |pos| path[0..pos] else path;
    const remaining = if (slash_pos) |pos| path[pos + 1 ..] else null;

    for (tree.entries) |entry| {
        if (std.mem.eql(u8, entry.name, first_component)) {
            if (remaining) |rest| {
                return getBlobFromTree(allocator, store, entry.sha, rest);
            } else {
                return getBlob(allocator, store, entry.sha);
            }
        }
    }

    return error.FileNotInTree;
}

fn getBlob(allocator: std.mem.Allocator, store: *object.ObjectStore, sha: object.Sha1) ![]u8 {
    const raw = try store.readRaw(sha);
    defer allocator.free(raw.data);

    if (!std.mem.eql(u8, raw.type_str, "blob")) return error.NotABlob;

    return try allocator.dupe(u8, raw.content);
}

test "diff basic" {
    // Would need temp repo with changes
}

test "diff commit range parse" {
    // Test that "abc..def" is parsed correctly
    const range = "abc123..def456";
    const dot_pos = std.mem.indexOf(u8, range, "..").?;
    try std.testing.expectEqualStrings("abc123", range[0..dot_pos]);
    try std.testing.expectEqualStrings("def456", range[dot_pos + 2 ..]);
}
