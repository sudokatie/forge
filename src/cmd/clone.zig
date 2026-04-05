// forge clone - clone a repository

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const refs_mod = @import("../refs/mod.zig");
const object = @import("../object/mod.zig");
const pack_mod = @import("../pack/mod.zig");
const index_mod = @import("../index/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    if (args.len == 0) {
        try stderr.writeAll("usage: forge clone <repository> [<directory>]\n");
        return;
    }

    const url = args[0];
    const dest = if (args.len > 1) args[1] else extractRepoName(url);

    try stdout.writeAll("Cloning into '");
    try stdout.writeAll(dest);
    try stdout.writeAll("'...\n");

    // Create destination directory
    std.fs.cwd().makeDir(dest) catch |err| {
        if (err != error.PathAlreadyExists) {
            try stderr.writeAll("fatal: destination path already exists\n");
            return;
        }
    };

    var dest_dir = try std.fs.cwd().openDir(dest, .{});
    defer dest_dir.close();

    // Initialize repository structure
    try dest_dir.makePath(".git/objects");
    try dest_dir.makePath(".git/refs/heads");
    try dest_dir.makePath(".git/refs/tags");
    try dest_dir.makePath(".git/refs/remotes/origin");

    // Create HEAD
    {
        const head = try dest_dir.createFile(".git/HEAD", .{});
        defer head.close();
        try head.writeAll("ref: refs/heads/main\n");
    }

    // Create config with remote
    {
        const config = try dest_dir.createFile(".git/config", .{});
        defer config.close();
        try config.writeAll("[core]\n    repositoryformatversion = 0\n    filemode = true\n    bare = false\n");
        try config.writeAll("[remote \"origin\"]\n    url = ");
        try config.writeAll(url);
        try config.writeAll("\n    fetch = +refs/heads/*:refs/remotes/origin/*\n");
    }

    // Discover refs
    try stdout.writeAll("Discovering refs...\n");
    var discovery = protocol.discoverRefs(allocator, url) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: could not read from remote repository: {any}\n", .{err}) catch "fatal: could not read from remote\n";
        try stderr.writeAll(msg);
        return;
    };
    defer discovery.deinit();

    if (discovery.refs.len == 0) {
        try stdout.writeAll("warning: remote HEAD is empty (empty repository)\n");
        return;
    }

    var buf: [64]u8 = undefined;
    const refs_msg = std.fmt.bufPrint(&buf, "Found {d} refs\n", .{discovery.refs.len}) catch "Found refs\n";
    try stdout.writeAll(refs_msg);

    // Collect SHAs we want
    var wants: std.ArrayList(object.Sha1) = .empty;
    defer wants.deinit(allocator);

    for (discovery.refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/") or
            std.mem.startsWith(u8, ref.name, "refs/tags/") or
            std.mem.eql(u8, ref.name, "HEAD"))
        {
            try wants.append(allocator, ref.sha);
        }
    }

    // Fetch pack file
    if (wants.items.len > 0) {
        try stdout.writeAll("Fetching objects...\n");

        const pack_data = protocol.fetchPack(allocator, url, wants.items, &.{}) catch |err| {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "warning: could not fetch pack: {any}\n", .{err}) catch "warning: fetch failed\n";
            try stderr.writeAll(err_msg);
            try stderr.writeAll("Continuing with refs only...\n");
            try setupRefs(allocator, dest_dir, &discovery);
            return;
        };
        defer allocator.free(pack_data);

        if (pack_data.len > 0 and std.mem.startsWith(u8, pack_data, "PACK")) {
            var pack_buf: [64]u8 = undefined;
            const pack_msg = std.fmt.bufPrint(&pack_buf, "Received pack: {d} bytes\n", .{pack_data.len}) catch "Received pack\n";
            try stdout.writeAll(pack_msg);

            try stdout.writeAll("Unpacking objects...\n");
            try unpackObjects(allocator, dest_dir, pack_data);
        }
    }

    // Set up refs
    try setupRefs(allocator, dest_dir, &discovery);

    // Checkout working tree
    const default_branch = protocol.findDefaultBranch(discovery.refs) orelse "main";

    try stdout.writeAll("Checking out '");
    try stdout.writeAll(default_branch);
    try stdout.writeAll("'...\n");
    try checkoutBranch(allocator, dest_dir, default_branch);

    try stdout.writeAll("Done.\n");
}

fn setupRefs(
    allocator: std.mem.Allocator,
    dest_dir: std.fs.Dir,
    discovery: *protocol.RefDiscovery,
) !void {
    for (discovery.refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            const branch = ref.name[11..];

            const remote_path = try std.fmt.allocPrint(allocator, ".git/refs/remotes/origin/{s}", .{branch});
            defer allocator.free(remote_path);

            if (std.mem.lastIndexOf(u8, remote_path, "/")) |pos| {
                dest_dir.makePath(remote_path[0..pos]) catch {};
            }

            const ref_file = dest_dir.createFile(remote_path, .{}) catch continue;
            defer ref_file.close();
            const hex = object.hash.toHex(ref.sha);
            try ref_file.writeAll(&hex);
            try ref_file.writeAll("\n");
        }
    }

    const default_branch = protocol.findDefaultBranch(discovery.refs) orelse "main";
    for (discovery.refs) |ref| {
        const branch_name = if (std.mem.eql(u8, ref.name, "refs/heads/main"))
            "main"
        else if (std.mem.eql(u8, ref.name, "refs/heads/master"))
            "master"
        else
            continue;

        if (std.mem.eql(u8, branch_name, default_branch)) {
            const local_path = try std.fmt.allocPrint(allocator, ".git/refs/heads/{s}", .{branch_name});
            defer allocator.free(local_path);

            const local_file = try dest_dir.createFile(local_path, .{});
            defer local_file.close();
            const hex = object.hash.toHex(ref.sha);
            try local_file.writeAll(&hex);
            try local_file.writeAll("\n");

            const head_file = try dest_dir.createFile(".git/HEAD", .{});
            defer head_file.close();
            try head_file.writeAll("ref: refs/heads/");
            try head_file.writeAll(branch_name);
            try head_file.writeAll("\n");
            break;
        }
    }
}

fn unpackObjects(allocator: std.mem.Allocator, dest_dir: std.fs.Dir, pack_data: []const u8) !void {
    _ = dest_dir;
    var pack = try pack_mod.Pack.parse(allocator, pack_data);

    var store = object.ObjectStore.init(allocator, ".git");

    var offset: usize = 12;

    for (0..pack.object_count) |_| {
        const obj = pack.readObject(offset) catch break;
        defer allocator.free(obj.data);

        var resolved_type: pack_mod.ObjectType = undefined;
        var resolved_data: []u8 = undefined;

        if (obj.obj_type == .ofs_delta or obj.obj_type == .ref_delta) {
            const r = pack.resolveObject(offset) catch continue;
            resolved_type = r.obj_type;
            resolved_data = r.data;
        } else {
            resolved_type = obj.obj_type;
            resolved_data = try allocator.dupe(u8, obj.data);
        }
        defer allocator.free(resolved_data);

        const store_type: object.ObjectType = switch (resolved_type) {
            .commit => .commit,
            .tree => .tree,
            .blob => .blob,
            .tag => .tag,
            else => continue,
        };

        _ = store.write(store_type, resolved_data) catch continue;

        offset += obj.consumed;
    }
}

fn checkoutBranch(allocator: std.mem.Allocator, dest_dir: std.fs.Dir, branch: []const u8) !void {
    const ref_path = try std.fmt.allocPrint(allocator, ".git/refs/heads/{s}", .{branch});
    defer allocator.free(ref_path);

    const sha_content = dest_dir.readFileAlloc(allocator, ref_path, 1024) catch return;
    defer allocator.free(sha_content);

    const sha_hex = std.mem.trimRight(u8, sha_content, "\n\r");
    if (sha_hex.len != 40) return;

    const commit_sha = object.hash.fromHex(sha_hex[0..40]) catch return;

    var store = object.ObjectStore.init(allocator, ".git");

    const commit_obj = store.read(commit_sha) catch return;
    if (commit_obj != .commit) return;

    const tree_sha = commit_obj.commit.tree;

    try checkoutTree(allocator, &store, tree_sha, ".", dest_dir);

    var idx = index_mod.Index.init(allocator);
    try buildIndex(allocator, &store, tree_sha, "", &idx, dest_dir);
    try idx.write(".git");
}

fn checkoutTree(
    allocator: std.mem.Allocator,
    store: *object.ObjectStore,
    tree_sha: object.Sha1,
    prefix: []const u8,
    dest_dir: std.fs.Dir,
) !void {
    const obj = try store.read(tree_sha);
    if (obj != .tree) return;

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
            dest_dir.makeDir(full_path) catch |err| {
                if (err != error.PathAlreadyExists) continue;
            };
            try checkoutTree(allocator, store, entry.sha, full_path, dest_dir);
        } else {
            const raw = store.readRaw(entry.sha) catch continue;
            defer allocator.free(raw.data);

            if (std.mem.lastIndexOf(u8, full_path, "/")) |pos| {
                dest_dir.makePath(full_path[0..pos]) catch {};
            }

            const file = dest_dir.createFile(full_path, .{}) catch continue;
            defer file.close();
            file.writeAll(raw.content) catch continue;
        }
    }
}

fn buildIndex(
    allocator: std.mem.Allocator,
    store: *object.ObjectStore,
    tree_sha: object.Sha1,
    prefix: []const u8,
    idx: *index_mod.Index,
    dest_dir: std.fs.Dir,
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
            try buildIndex(allocator, store, entry.sha, full_path, idx, dest_dir);
        } else {
            const stat = dest_dir.statFile(full_path) catch {
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

fn extractRepoName(url: []const u8) []const u8 {
    var name = url;

    if (std.mem.endsWith(u8, name, "/")) {
        name = name[0 .. name.len - 1];
    }

    if (std.mem.endsWith(u8, name, ".git")) {
        name = name[0 .. name.len - 4];
    }

    if (std.mem.lastIndexOf(u8, name, "/")) |pos| {
        name = name[pos + 1 ..];
    }

    if (std.mem.lastIndexOf(u8, name, ":")) |pos| {
        name = name[pos + 1 ..];
    }

    return name;
}

test "extract repo name" {
    try std.testing.expectEqualStrings("repo", extractRepoName("https://github.com/user/repo.git"));
    try std.testing.expectEqualStrings("repo", extractRepoName("https://github.com/user/repo"));
    try std.testing.expectEqualStrings("repo", extractRepoName("git@github.com:user/repo.git"));
}
