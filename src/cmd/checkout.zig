// forge checkout - switch branches or restore working tree files

const std = @import("std");
const object = @import("../object/mod.zig");
const refs = @import("../refs/mod.zig");
const index_mod = @import("../index/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var create_branch = false;
    var restore_file = false;
    var target: ?[]const u8 = null;
    var file_paths: std.ArrayList([]const u8) = .empty;
    defer file_paths.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-b")) {
            create_branch = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            restore_file = true;
            i += 1;
            while (i < args.len) : (i += 1) {
                try file_paths.append(allocator, args[i]);
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (target == null) {
                target = arg;
            } else {
                restore_file = true;
                try file_paths.append(allocator, arg);
            }
        }
    }

    if (target == null and file_paths.items.len == 0) {
        try stderr.writeAll("usage: forge checkout [-b] <branch>\n");
        try stderr.writeAll("   or: forge checkout [--] <file>...\n");
        return;
    }

    var ref_store = refs.RefStore.init(allocator, ".git");
    var store = object.ObjectStore.init(allocator, ".git");
    const cwd = std.fs.cwd();

    // Restore specific files from index
    if (restore_file and file_paths.items.len > 0) {
        var idx = try index_mod.Index.read(allocator, ".git");
        defer idx.deinit();

        for (file_paths.items) |path| {
            var found = false;
            for (idx.entries) |entry| {
                if (std.mem.eql(u8, entry.path, path)) {
                    const raw = store.readRaw(entry.sha) catch {
                        var buf: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "error: could not read '{s}' from index\n", .{path}) catch "error reading file\n";
                        try stderr.writeAll(msg);
                        continue;
                    };
                    defer allocator.free(raw.data);

                    if (std.mem.lastIndexOf(u8, path, "/")) |pos| {
                        cwd.makePath(path[0..pos]) catch {};
                    }

                    const file = cwd.createFile(path, .{}) catch |err| {
                        var buf: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "error: could not write '{s}': {any}\n", .{ path, err }) catch "error writing file\n";
                        try stderr.writeAll(msg);
                        continue;
                    };
                    defer file.close();
                    try file.writeAll(raw.content);

                    try stdout.writeAll("Updated '");
                    try stdout.writeAll(path);
                    try stdout.writeAll("'\n");
                    found = true;
                    break;
                }
            }
            if (!found) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: pathspec '{s}' did not match any file(s)\n", .{path}) catch "error: file not found\n";
                try stderr.writeAll(msg);
            }
        }
        return;
    }

    const branch_target = target.?;

    if (create_branch) {
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

        const ref_path = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_target});
        defer allocator.free(ref_path);
        try ref_store.update(ref_path, sha);

        const head_file = try cwd.createFile(".git/HEAD", .{});
        defer head_file.close();
        const head_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{branch_target});
        defer allocator.free(head_content);
        try head_file.writeAll(head_content);

        try stdout.writeAll("Switched to a new branch '");
        try stdout.writeAll(branch_target);
        try stdout.writeAll("'\n");
        return;
    }

    // Switch to existing branch
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_target});
    defer allocator.free(branch_ref);

    const branch_sha = ref_store.resolve(branch_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: pathspec '{s}' did not match any file(s) known to forge.\n", .{branch_target}) catch "error: branch not found\n";
        try stderr.writeAll(msg);
        return;
    };

    // Update working tree from branch's commit
    const commit_obj = store.read(branch_sha) catch {
        try stderr.writeAll("error: could not read commit\n");
        return;
    };
    if (commit_obj != .commit) {
        try stderr.writeAll("error: not a commit\n");
        return;
    }

    const tree_sha = commit_obj.commit.tree;

    // Update working tree
    try updateWorkingTree(allocator, &store, tree_sha, ".", cwd);

    // Update index to match tree
    var new_idx = index_mod.Index.init(allocator);
    try buildIndexFromTree(allocator, &store, tree_sha, "", &new_idx, cwd);
    try new_idx.write(".git");

    // Update HEAD
    const head_file = try cwd.createFile(".git/HEAD", .{});
    defer head_file.close();
    const head_content = try std.fmt.allocPrint(allocator, "ref: {s}\n", .{branch_ref});
    defer allocator.free(head_content);
    try head_file.writeAll(head_content);

    try stdout.writeAll("Switched to branch '");
    try stdout.writeAll(branch_target);
    try stdout.writeAll("'\n");
}

fn updateWorkingTree(
    allocator: std.mem.Allocator,
    store: *object.ObjectStore,
    tree_sha: object.Sha1,
    prefix: []const u8,
    cwd: std.fs.Dir,
) !void {
    const obj = try store.read(tree_sha);
    if (obj != .tree) return error.NotATree;

    const tree = obj.tree;
    defer {
        var t = tree;
        t.deinit();
    }

    for (tree.entries) |entry| {
        const full_path = if (std.mem.eql(u8, prefix, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(full_path);

        if (entry.mode == 0o40000) {
            cwd.makeDir(full_path) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
            try updateWorkingTree(allocator, store, entry.sha, full_path, cwd);
        } else {
            const raw = try store.readRaw(entry.sha);
            defer allocator.free(raw.data);

            if (std.mem.lastIndexOf(u8, full_path, "/")) |pos| {
                cwd.makePath(full_path[0..pos]) catch {};
            }

            const file = try cwd.createFile(full_path, .{});
            defer file.close();
            try file.writeAll(raw.content);
        }
    }
}

fn buildIndexFromTree(
    allocator: std.mem.Allocator,
    store: *object.ObjectStore,
    tree_sha: object.Sha1,
    prefix: []const u8,
    idx: *index_mod.Index,
    cwd: std.fs.Dir,
) !void {
    const obj = try store.read(tree_sha);
    if (obj != .tree) return;

    const tree = obj.tree;
    defer {
        var t = tree;
        t.deinit();
    }

    for (tree.entries) |entry| {
        const full_path = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });

        if (entry.mode == 0o40000) {
            defer allocator.free(full_path);
            try buildIndexFromTree(allocator, store, entry.sha, full_path, idx, cwd);
        } else {
            const stat = cwd.statFile(full_path) catch {
                allocator.free(full_path);
                continue;
            };

            try idx.add(.{
                .ctime_s = @intCast(@divTrunc(stat.ctime, std.time.ns_per_s)),
                .ctime_ns = @intCast(@mod(stat.ctime, std.time.ns_per_s)),
                .mtime_s = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s)),
                .mtime_ns = @intCast(@mod(stat.mtime, std.time.ns_per_s)),
                .dev = 0,
                .ino = 0,
                .mode = entry.mode,
                .uid = 0,
                .gid = 0,
                .size = @intCast(stat.size),
                .sha = entry.sha,
                .flags = 0,
                .path = full_path,
            });
        }
    }
}

test "checkout basic" {
    // Would need temp repo
}
