// forge update-index - modify index directly

const std = @import("std");
const object = @import("../object/mod.zig");
const index_mod = @import("../index/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var add_files: std.ArrayList([]const u8) = .empty;
    defer add_files.deinit(allocator);
    var remove_files: std.ArrayList([]const u8) = .empty;
    defer remove_files.deinit(allocator);
    var refresh = false;
    var cacheinfo: ?struct { mode: u32, sha: object.Sha1, path: []const u8 } = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--add")) {
            if (i + 1 < args.len) {
                i += 1;
                try add_files.append(allocator, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--remove")) {
            if (i + 1 < args.len) {
                i += 1;
                try remove_files.append(allocator, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            refresh = true;
        } else if (std.mem.eql(u8, arg, "--cacheinfo")) {
            if (i + 1 >= args.len) {
                try stderr.writeAll("error: --cacheinfo requires arguments\n");
                return;
            }
            i += 1;
            const info = args[i];

            // Try comma-separated format first
            if (std.mem.indexOf(u8, info, ",")) |_| {
                var parts = std.mem.splitScalar(u8, info, ',');
                const mode_str = parts.next() orelse {
                    try stderr.writeAll("error: invalid --cacheinfo format\n");
                    return;
                };
                const sha_str = parts.next() orelse {
                    try stderr.writeAll("error: invalid --cacheinfo format\n");
                    return;
                };
                const path = parts.next() orelse {
                    try stderr.writeAll("error: invalid --cacheinfo format\n");
                    return;
                };

                const mode = std.fmt.parseInt(u32, mode_str, 8) catch {
                    try stderr.writeAll("error: invalid mode\n");
                    return;
                };
                if (sha_str.len != 40) {
                    try stderr.writeAll("error: invalid sha\n");
                    return;
                }
                const sha = object.hash.fromHex(sha_str[0..40]) catch {
                    try stderr.writeAll("error: invalid sha\n");
                    return;
                };

                cacheinfo = .{ .mode = mode, .sha = sha, .path = path };
            } else {
                // Space-separated: mode sha path
                if (i + 2 >= args.len) {
                    try stderr.writeAll("error: --cacheinfo requires mode sha path\n");
                    return;
                }
                const mode = std.fmt.parseInt(u32, info, 8) catch {
                    try stderr.writeAll("error: invalid mode\n");
                    return;
                };
                i += 1;
                const sha_str = args[i];
                if (sha_str.len != 40) {
                    try stderr.writeAll("error: invalid sha\n");
                    return;
                }
                const sha = object.hash.fromHex(sha_str[0..40]) catch {
                    try stderr.writeAll("error: invalid sha\n");
                    return;
                };
                i += 1;
                const path = args[i];

                cacheinfo = .{ .mode = mode, .sha = sha, .path = path };
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try add_files.append(allocator, arg);
        }
    }

    var idx = try index_mod.Index.read(allocator, ".git");
    defer idx.deinit();

    const cwd = std.fs.cwd();
    var store = object.ObjectStore.init(allocator, ".git");

    // Handle --cacheinfo
    if (cacheinfo) |ci| {
        try idx.add(.{
            .ctime_s = 0,
            .ctime_ns = 0,
            .mtime_s = 0,
            .mtime_ns = 0,
            .dev = 0,
            .ino = 0,
            .mode = ci.mode,
            .uid = 0,
            .gid = 0,
            .size = 0,
            .sha = ci.sha,
            .flags = 0,
            .path = try allocator.dupe(u8, ci.path),
        });
    }

    // Add files
    for (add_files.items) |path| {
        const content = cwd.readFileAlloc(allocator, path, 100 * 1024 * 1024) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: '{s}': {any}\n", .{ path, err }) catch "error: file not found\n";
            try stderr.writeAll(msg);
            continue;
        };
        defer allocator.free(content);

        const stat = cwd.statFile(path) catch continue;
        const sha = try store.write(.blob, content);

        try idx.add(.{
            .ctime_s = @intCast(@divTrunc(stat.ctime, std.time.ns_per_s)),
            .ctime_ns = @intCast(@mod(stat.ctime, std.time.ns_per_s)),
            .mtime_s = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s)),
            .mtime_ns = @intCast(@mod(stat.mtime, std.time.ns_per_s)),
            .dev = 0,
            .ino = 0,
            .mode = 0o100644,
            .uid = 0,
            .gid = 0,
            .size = @intCast(stat.size),
            .sha = sha,
            .flags = 0,
            .path = try allocator.dupe(u8, path),
        });
    }

    // Remove files
    for (remove_files.items) |path| {
        _ = idx.remove(path);
    }

    // Refresh (update stat info for unchanged files)
    if (refresh) {
        for (idx.entries) |*entry| {
            const stat = cwd.statFile(entry.path) catch continue;
            entry.mtime_s = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
            entry.mtime_ns = @intCast(@mod(stat.mtime, std.time.ns_per_s));
            entry.ctime_s = @intCast(@divTrunc(stat.ctime, std.time.ns_per_s));
            entry.ctime_ns = @intCast(@mod(stat.ctime, std.time.ns_per_s));
            entry.size = @intCast(stat.size);
        }
    }

    try idx.write(".git");
}

test "update-index basic" {
    // Would need temp repo
}
