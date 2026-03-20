// forge push - push local changes to remote

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const refs_mod = @import("../refs/mod.zig");
const object = @import("../object/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    // Parse arguments
    var remote: []const u8 = "origin";
    var branch: ?[]const u8 = null;
    var force = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (branch == null and !std.mem.startsWith(u8, arg, "-")) {
            if (remote.len > 0 and std.mem.eql(u8, remote, "origin")) {
                remote = arg;
            } else {
                branch = arg;
            }
        }
    }
    _ = force; // Will be used when actual push is implemented

    // Read remote URL
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
        const msg = std.fmt.bufPrint(&buf, "error: src refspec {s} does not match any\n", .{push_branch}) catch {
            try stderr.writeAll("error: branch not found\n");
            return;
        };
        try stderr.writeAll(msg);
        return;
    };

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

    // Find remote ref
    var remote_sha: ?object.Sha1 = null;
    for (discovery.refs) |ref| {
        if (std.mem.eql(u8, ref.name, ref_path)) {
            remote_sha = ref.sha;
            break;
        }
    }

    const local_hex = object.hash.toHex(local_sha);

    if (remote_sha) |rs| {
        const remote_hex = object.hash.toHex(rs);
        if (std.mem.eql(u8, &local_hex, &remote_hex)) {
            try stdout.writeAll("Everything up-to-date\n");
            return;
        }
    }

    // TODO: Generate pack and send to remote
    // For now, show what would be pushed
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, 
        \\Pushing to {s}
        \\  {s} -> refs/heads/{s}
        \\  Local:  {s}
        \\  Remote: {s}
        \\
        \\Note: Actual pack upload not yet implemented
        \\
    , .{
        url,
        push_branch, push_branch,
        local_hex[0..7],
        if (remote_sha) |rs| object.hash.toHex(rs)[0..7] else "(new)",
    }) catch {
        try stdout.writeAll("Push dry run complete\n");
        return;
    };
    try stdout.writeAll(msg);
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
