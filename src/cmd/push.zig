// forge push - push local changes to remote

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const refs_mod = @import("../refs/mod.zig");
const object = @import("../object/mod.zig");
const pack_mod = @import("../pack/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var remote: []const u8 = "origin";
    var branch: ?[]const u8 = null;
    var force = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, remote, "origin")) {
                remote = arg;
            } else if (branch == null) {
                branch = arg;
            }
        }
    }

    // Read remote URL
    const url = readRemoteUrl(allocator, remote) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' does not appear to be a git repository\n", .{remote}) catch "fatal: remote not found\n";
        try stderr.writeAll(msg);
        return;
    };
    defer allocator.free(url);

    // Get current branch if not specified
    const push_branch = branch orelse getCurrentBranch(allocator) orelse {
        try stderr.writeAll("fatal: no branch specified and not on a branch\n");
        return;
    };
    defer if (branch == null) allocator.free(push_branch);

    // Get local ref
    var ref_store = refs_mod.RefStore.init(allocator, ".git");
    const ref_path = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{push_branch});
    defer allocator.free(ref_path);

    const local_sha = ref_store.resolve(ref_path) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: src refspec {s} does not match any\n", .{push_branch}) catch "error: branch not found\n";
        try stderr.writeAll(msg);
        return;
    };

    try stdout.writeAll("Pushing to ");
    try stdout.writeAll(url);
    try stdout.writeAll("\n");

    // Discover remote refs
    var discovery = protocol.discoverRefs(allocator, url) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: could not read from remote: {any}\n", .{err}) catch "fatal: network error\n";
        try stderr.writeAll(msg);
        return;
    };
    defer discovery.deinit();

    // Find remote ref
    var remote_sha: ?object.Sha1 = null;
    for (discovery.refs) |ref| {
        if (std.mem.eql(u8, ref.name, ref_path)) {
            remote_sha = ref.sha;
            break;
        }
    }

    const local_hex = object.hash.toHex(local_sha);

    // Check if already up to date
    if (remote_sha) |rs| {
        const remote_hex = object.hash.toHex(rs);
        if (std.mem.eql(u8, &local_hex, &remote_hex)) {
            try stdout.writeAll("Everything up-to-date\n");
            return;
        }

        // Check for non-fast-forward
        if (!force) {
            if (!isAncestor(allocator, rs, local_sha)) {
                try stderr.writeAll("error: failed to push some refs\n");
                try stderr.writeAll("hint: Updates were rejected because the tip of your current branch is behind\n");
                try stderr.writeAll("hint: its remote counterpart. Use -f to force.\n");
                return;
            }
        }
    }

    // Collect objects to send
    var store = object.ObjectStore.init(allocator, ".git");
    var objects_to_send: std.ArrayList(PackObjectEntry) = .empty;
    defer {
        for (objects_to_send.items) |entry| {
            allocator.free(entry.data);
        }
        objects_to_send.deinit(allocator);
    }

    try collectObjects(allocator, &store, local_sha, remote_sha, &objects_to_send);

    if (objects_to_send.items.len == 0) {
        try stdout.writeAll("Everything up-to-date\n");
        return;
    }

    var count_buf: [64]u8 = undefined;
    const count_msg = std.fmt.bufPrint(&count_buf, "Pushing {d} objects...\n", .{objects_to_send.items.len}) catch "Pushing...\n";
    try stdout.writeAll(count_msg);

    // Build pack file
    var pack_writer = pack_mod.PackWriter.init(allocator);
    defer pack_writer.deinit();

    for (objects_to_send.items) |entry| {
        try pack_writer.addObject(entry.obj_type, entry.data, entry.sha);
    }

    const pack_data = try pack_writer.write();
    defer allocator.free(pack_data);

    var size_buf: [64]u8 = undefined;
    const size_msg = std.fmt.bufPrint(&size_buf, "Pack size: {d} bytes\n", .{pack_data.len}) catch "Pack ready\n";
    try stdout.writeAll(size_msg);

    // Push to remote
    const old_sha = remote_sha orelse std.mem.zeroes(object.Sha1);

    protocol.pushPack(allocator, url, &.{
        .{
            .ref_name = ref_path,
            .old_sha = old_sha,
            .new_sha = local_sha,
        },
    }, pack_data) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "error: push failed: {any}\n", .{err}) catch "push failed\n";
        try stderr.writeAll(err_msg);
        return;
    };

    const short_sha = local_hex[0..7];
    if (remote_sha) |rs| {
        const old_short = object.hash.toHex(rs)[0..7];
        if (force) {
            try stdout.writeAll(" + ");
            try stdout.writeAll(old_short);
            try stdout.writeAll("...");
            try stdout.writeAll(short_sha);
            try stdout.writeAll(" ");
            try stdout.writeAll(push_branch);
            try stdout.writeAll(" -> ");
            try stdout.writeAll(push_branch);
            try stdout.writeAll(" (forced update)\n");
        } else {
            try stdout.writeAll("   ");
            try stdout.writeAll(old_short);
            try stdout.writeAll("..");
            try stdout.writeAll(short_sha);
            try stdout.writeAll("  ");
            try stdout.writeAll(push_branch);
            try stdout.writeAll(" -> ");
            try stdout.writeAll(push_branch);
            try stdout.writeAll("\n");
        }
    } else {
        try stdout.writeAll(" * [new branch]      ");
        try stdout.writeAll(push_branch);
        try stdout.writeAll(" -> ");
        try stdout.writeAll(push_branch);
        try stdout.writeAll("\n");
    }

    try stdout.writeAll("Done.\n");
}

const PackObjectEntry = struct {
    obj_type: pack_mod.ObjectType,
    data: []u8,
    sha: object.Sha1,
};

fn collectObjects(
    allocator: std.mem.Allocator,
    store: *object.ObjectStore,
    commit_sha: object.Sha1,
    stop_at: ?object.Sha1,
    objects: *std.ArrayList(PackObjectEntry),
) !void {
    var visited = std.AutoHashMap(object.Sha1, void).init(allocator);
    defer visited.deinit();

    var queue: std.ArrayList(object.Sha1) = .empty;
    defer queue.deinit(allocator);

    try queue.append(allocator, commit_sha);

    while (queue.items.len > 0) {
        const sha = queue.pop() orelse break;

        if (visited.contains(sha)) continue;
        try visited.put(sha, {});

        if (stop_at) |stop| {
            if (std.mem.eql(u8, &sha, &stop)) continue;
        }

        const raw = store.readRaw(sha) catch continue;
        defer allocator.free(raw.data);

        const obj_type: pack_mod.ObjectType = if (std.mem.eql(u8, raw.type_str, "commit"))
            .commit
        else if (std.mem.eql(u8, raw.type_str, "tree"))
            .tree
        else if (std.mem.eql(u8, raw.type_str, "blob"))
            .blob
        else if (std.mem.eql(u8, raw.type_str, "tag"))
            .tag
        else
            continue;

        try objects.append(allocator, .{
            .obj_type = obj_type,
            .data = try allocator.dupe(u8, raw.content),
            .sha = sha,
        });

        // Queue referenced objects
        if (std.mem.eql(u8, raw.type_str, "commit")) {
            const commit_obj = try object.commit.parse(allocator, raw.content);
            defer {
                var c = commit_obj;
                c.deinit();
            }

            try queue.append(allocator, commit_obj.tree);
            for (commit_obj.parents) |parent| {
                try queue.append(allocator, parent);
            }
        } else if (std.mem.eql(u8, raw.type_str, "tree")) {
            const tree_obj = try object.tree.parse(allocator, raw.content);
            defer {
                var t = tree_obj;
                t.deinit();
            }

            for (tree_obj.entries) |entry| {
                try queue.append(allocator, entry.sha);
            }
        }
    }
}

fn isAncestor(allocator: std.mem.Allocator, ancestor: object.Sha1, descendant: object.Sha1) bool {
    var store = object.ObjectStore.init(allocator, ".git");

    var visited = std.AutoHashMap(object.Sha1, void).init(allocator);
    defer visited.deinit();

    var queue: std.ArrayList(object.Sha1) = .empty;
    defer queue.deinit(allocator);

    queue.append(allocator, descendant) catch return false;

    while (queue.items.len > 0) {
        const sha = queue.pop() orelse break;

        if (std.mem.eql(u8, &sha, &ancestor)) return true;

        if (visited.contains(sha)) continue;
        visited.put(sha, {}) catch continue;

        const obj = store.read(sha) catch continue;
        if (obj != .commit) continue;

        for (obj.commit.parents) |parent| {
            queue.append(allocator, parent) catch continue;
        }
    }

    return false;
}

fn readRemoteUrl(allocator: std.mem.Allocator, remote: []const u8) ![]u8 {
    const config = std.fs.cwd().readFileAlloc(allocator, ".git/config", 64 * 1024) catch return error.ConfigNotFound;
    defer allocator.free(config);

    const remote_header = try std.fmt.allocPrint(allocator, "[remote \"{s}\"]", .{remote});
    defer allocator.free(remote_header);

    if (std.mem.indexOf(u8, config, remote_header)) |section_start| {
        const section = config[section_start..];
        var lines = std.mem.splitSequence(u8, section, "\n");
        _ = lines.next();

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '[') break;

            if (std.mem.startsWith(u8, trimmed, "url")) {
                if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                    const url_val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
                    return try allocator.dupe(u8, url_val);
                }
            }
        }
    }

    return error.RemoteNotFound;
}

fn getCurrentBranch(allocator: std.mem.Allocator) ?[]u8 {
    const head = std.fs.cwd().readFileAlloc(allocator, ".git/HEAD", 1024) catch return null;
    defer allocator.free(head);

    const trimmed = std.mem.trimRight(u8, head, "\n\r");
    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
        return allocator.dupe(u8, trimmed[16..]) catch null;
    }

    return null;
}

test "get current branch" {
    // Would need temp git repo
}
