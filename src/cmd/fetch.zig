// forge fetch - download objects and refs from remote

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const refs_mod = @import("../refs/mod.zig");
const object = @import("../object/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    // Default remote is "origin"
    const remote = if (args.len > 0) args[0] else "origin";

    // Read remote URL from config
    const url = readRemoteUrl(allocator, remote) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' does not appear to be a git repository\n", .{remote}) catch {
            try stderr.writeAll("fatal: remote not found\n");
            return;
        };
        try stderr.writeAll(msg);
        return;
    };
    defer allocator.free(url);

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Fetching {s}\n", .{remote}) catch {
        try stdout.writeAll("Fetching...\n");
        return error.FormatError;
    };
    try stdout.writeAll(msg);

    // Discover remote refs
    var discovery = protocol.discoverRefs(allocator, url) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "fatal: could not read from remote: {any}\n", .{err}) catch {
            try stderr.writeAll("fatal: could not read from remote\n");
            return;
        };
        try stderr.writeAll(err_msg);
        return;
    };
    defer discovery.deinit();

    // Update remote-tracking refs
    var updated: usize = 0;
    const cwd = std.fs.cwd();

    for (discovery.refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            const branch = ref.name[11..];
            const ref_path = try std.fmt.allocPrint(allocator, ".git/refs/remotes/{s}/{s}", .{ remote, branch });
            defer allocator.free(ref_path);

            // Read existing ref
            const existing = cwd.readFileAlloc(allocator, ref_path, 1024) catch null;
            const existing_trimmed = if (existing) |e| blk: {
                defer allocator.free(e);
                break :blk std.mem.trimRight(u8, e, "\n\r");
            } else "";

            const new_sha = object.hash.toHex(ref.sha);

            // Only update if changed
            if (!std.mem.eql(u8, existing_trimmed, &new_sha)) {
                // Create parent directory if needed
                if (std.mem.lastIndexOf(u8, ref_path, "/")) |pos| {
                    cwd.makePath(ref_path[0..pos]) catch {};
                }

                const ref_file = cwd.createFile(ref_path, .{}) catch continue;
                defer ref_file.close();
                ref_file.writer().print("{s}\n", .{new_sha}) catch continue;
                updated += 1;

                var update_buf: [256]u8 = undefined;
                const update_msg = std.fmt.bufPrint(&update_buf, " * [updated] {s}/{s}\n", .{ remote, branch }) catch continue;
                try stdout.writeAll(update_msg);
            }
        }
    }

    if (updated == 0) {
        try stdout.writeAll("Already up to date.\n");
    } else {
        var done_buf: [128]u8 = undefined;
        const done_msg = std.fmt.bufPrint(&done_buf, "Updated {d} refs\n", .{updated}) catch {
            try stdout.writeAll("Done.\n");
            return;
        };
        try stdout.writeAll(done_msg);
    }

    // TODO: Fetch actual pack data
    try stdout.writeAll("Note: Object fetch not yet implemented - refs only\n");
}

fn readRemoteUrl(allocator: std.mem.Allocator, remote: []const u8) ![]u8 {
    const config = std.fs.cwd().readFileAlloc(allocator, ".git/config", 64 * 1024) catch return error.ConfigNotFound;
    defer allocator.free(config);

    // Simple config parser - find [remote "name"] section and url = line
    const remote_header = try std.fmt.allocPrint(allocator, "[remote \"{s}\"]", .{remote});
    defer allocator.free(remote_header);

    if (std.mem.indexOf(u8, config, remote_header)) |section_start| {
        const section = config[section_start..];
        var lines = std.mem.splitSequence(u8, section, "\n");
        _ = lines.next(); // Skip header

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '[') break; // Next section

            if (std.mem.startsWith(u8, trimmed, "url")) {
                if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                    const url = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
                    return try allocator.dupe(u8, url);
                }
            }
        }
    }

    return error.RemoteNotFound;
}

test "read remote url" {
    // Would need temp git config
}
