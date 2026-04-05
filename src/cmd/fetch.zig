// forge fetch - download objects and refs from remote

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const refs_mod = @import("../refs/mod.zig");
const object = @import("../object/mod.zig");
const pack_mod = @import("../pack/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    const remote = if (args.len > 0) args[0] else "origin";

    // Read remote URL from config
    const url = readRemoteUrl(allocator, remote) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' does not appear to be a git repository\n", .{remote}) catch "fatal: remote not found\n";
        try stderr.writeAll(msg);
        return;
    };
    defer allocator.free(url);

    try stdout.writeAll("Fetching ");
    try stdout.writeAll(remote);
    try stdout.writeAll("\n");

    // Discover remote refs
    var discovery = protocol.discoverRefs(allocator, url) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: could not read from remote: {any}\n", .{err}) catch "fatal: network error\n";
        try stderr.writeAll(msg);
        return;
    };
    defer discovery.deinit();

    // Collect what we want vs what we have
    var wants: std.ArrayList(object.Sha1) = .empty;
    defer wants.deinit(allocator);
    var haves: std.ArrayList(object.Sha1) = .empty;
    defer haves.deinit(allocator);

    var store = object.ObjectStore.init(allocator, ".git");
    const cwd = std.fs.cwd();

    for (discovery.refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            if (!store.exists(ref.sha)) {
                try wants.append(allocator, ref.sha);
            }

            const branch = ref.name[11..];
            const local_ref = try std.fmt.allocPrint(allocator, ".git/refs/remotes/{s}/{s}", .{ remote, branch });
            defer allocator.free(local_ref);

            const existing = cwd.readFileAlloc(allocator, local_ref, 1024) catch null;
            if (existing) |e| {
                defer allocator.free(e);
                const trimmed = std.mem.trimRight(u8, e, "\n\r");
                if (trimmed.len == 40) {
                    if (object.hash.fromHex(trimmed[0..40])) |sha| {
                        try haves.append(allocator, sha);
                    } else |_| {}
                }
            }
        }
    }

    // Fetch pack if we need objects
    if (wants.items.len > 0) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Fetching {d} objects...\n", .{wants.items.len}) catch "Fetching...\n";
        try stdout.writeAll(msg);

        const pack_data = protocol.fetchPack(allocator, url, wants.items, haves.items) catch |err| {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "warning: could not fetch pack: {any}\n", .{err}) catch "fetch failed\n";
            try stderr.writeAll(err_msg);
            try stderr.writeAll("Continuing with refs only...\n");
            try updateRefs(allocator, remote, &discovery, stdout);
            return;
        };
        defer allocator.free(pack_data);

        if (pack_data.len > 0 and std.mem.startsWith(u8, pack_data, "PACK")) {
            var size_buf: [64]u8 = undefined;
            const size_msg = std.fmt.bufPrint(&size_buf, "Received {d} bytes\n", .{pack_data.len}) catch "Received pack\n";
            try stdout.writeAll(size_msg);

            try unpackObjects(allocator, pack_data, &store);
        }
    }

    // Update refs
    try updateRefs(allocator, remote, &discovery, stdout);

    try stdout.writeAll("Done.\n");
}

fn updateRefs(
    allocator: std.mem.Allocator,
    remote: []const u8,
    discovery: *protocol.RefDiscovery,
    stdout: std.fs.File,
) !void {
    const cwd = std.fs.cwd();
    var updated: usize = 0;

    for (discovery.refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            const branch = ref.name[11..];
            const ref_path = try std.fmt.allocPrint(allocator, ".git/refs/remotes/{s}/{s}", .{ remote, branch });
            defer allocator.free(ref_path);

            const existing = cwd.readFileAlloc(allocator, ref_path, 1024) catch null;
            const existing_trimmed = if (existing) |e| blk: {
                defer allocator.free(e);
                break :blk std.mem.trimRight(u8, e, "\n\r");
            } else "";

            const new_sha = object.hash.toHex(ref.sha);

            if (!std.mem.eql(u8, existing_trimmed, &new_sha)) {
                if (std.mem.lastIndexOf(u8, ref_path, "/")) |pos| {
                    cwd.makePath(ref_path[0..pos]) catch {};
                }

                const ref_file = cwd.createFile(ref_path, .{}) catch continue;
                defer ref_file.close();
                try ref_file.writeAll(&new_sha);
                try ref_file.writeAll("\n");

                updated += 1;
                try stdout.writeAll(" * [updated] ");
                try stdout.writeAll(remote);
                try stdout.writeAll("/");
                try stdout.writeAll(branch);
                try stdout.writeAll("\n");
            }
        }
    }

    if (updated == 0) {
        try stdout.writeAll("Already up to date.\n");
    } else {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Updated {d} refs\n", .{updated}) catch "Updated refs\n";
        try stdout.writeAll(msg);
    }
}

fn unpackObjects(
    allocator: std.mem.Allocator,
    pack_data: []const u8,
    store: *object.ObjectStore,
) !void {
    var pack = try pack_mod.Pack.parse(allocator, pack_data);

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

test "read remote url" {
    // Would need temp git config
}
