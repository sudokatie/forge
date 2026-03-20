// forge clone - clone a repository

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const refs_mod = @import("../refs/mod.zig");
const object = @import("../object/mod.zig");
const init_cmd = @import("init.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    if (args.len == 0) {
        try stderr.writeAll("usage: forge clone <repository> [<directory>]\n");
        return;
    }

    const url = args[0];

    // Determine destination directory
    const dest = if (args.len > 1) args[1] else extractRepoName(url);

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Cloning into '{s}'...\n", .{dest}) catch {
        try stdout.writeAll("Cloning...\n");
        return error.FormatError;
    };
    try stdout.writeAll(msg);

    // Create destination directory
    std.fs.cwd().makeDir(dest) catch |err| {
        if (err != error.PathAlreadyExists) {
            try stderr.writeAll("fatal: destination path already exists\n");
            return;
        }
    };

    // Change to destination
    var dest_dir = try std.fs.cwd().openDir(dest, .{});
    defer dest_dir.close();

    // Initialize repository
    try dest_dir.makePath(".git/objects");
    try dest_dir.makePath(".git/refs/heads");
    try dest_dir.makePath(".git/refs/tags");
    try dest_dir.makePath(".git/refs/remotes/origin");

    // Create HEAD
    const head = try dest_dir.createFile(".git/HEAD", .{});
    defer head.close();
    try head.writeAll("ref: refs/heads/main\n");

    // Create config with remote
    const config = try dest_dir.createFile(".git/config", .{});
    defer config.close();
    try config.writer().print(
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\[remote "origin"]
        \\    url = {s}
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
    , .{url});

    // Discover refs
    try stdout.writeAll("Discovering refs...\n");
    var discovery = protocol.discoverRefs(allocator, url) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "fatal: could not read from remote repository: {any}\n", .{err}) catch {
            try stderr.writeAll("fatal: could not read from remote repository\n");
            return;
        };
        try stderr.writeAll(err_msg);
        return;
    };
    defer discovery.deinit();

    if (discovery.refs.len == 0) {
        try stdout.writeAll("warning: remote HEAD is empty (empty repository)\n");
        return;
    }

    // Set up remote tracking refs
    for (discovery.refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            const branch = ref.name[11..];
            const ref_path = try std.fmt.allocPrint(allocator, ".git/refs/remotes/origin/{s}", .{branch});
            defer allocator.free(ref_path);

            const ref_file = dest_dir.createFile(ref_path, .{}) catch continue;
            defer ref_file.close();
            try ref_file.writer().print("{s}\n", .{object.hash.toHex(ref.sha)});
        }
    }

    // Find default branch
    const default_branch = protocol.http.findDefaultBranch(discovery.refs) orelse "main";

    // Update HEAD to point to default branch
    const head_update = try dest_dir.createFile(".git/HEAD", .{});
    defer head_update.close();
    try head_update.writer().print("ref: refs/heads/{s}\n", .{default_branch});

    // Create local branch pointing to same commit as remote
    for (discovery.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "refs/heads/main") or std.mem.eql(u8, ref.name, "refs/heads/master")) {
            const branch_name = if (std.mem.eql(u8, ref.name, "refs/heads/main")) "main" else "master";
            const local_ref = try std.fmt.allocPrint(allocator, ".git/refs/heads/{s}", .{branch_name});
            defer allocator.free(local_ref);

            const local_file = try dest_dir.createFile(local_ref, .{});
            defer local_file.close();
            try local_file.writer().print("{s}\n", .{object.hash.toHex(ref.sha)});
            break;
        }
    }

    // TODO: Fetch pack file and checkout working tree
    // For now, just set up the refs

    var done_buf: [256]u8 = undefined;
    const done_msg = std.fmt.bufPrint(&done_buf, "Repository initialized with {d} refs from {s}\n", .{ discovery.refs.len, url }) catch {
        try stdout.writeAll("Done.\n");
        return;
    };
    try stdout.writeAll(done_msg);
    try stdout.writeAll("Note: Object fetch not yet implemented - refs only\n");
}

fn extractRepoName(url: []const u8) []const u8 {
    // Get last path component, strip .git
    var name = url;

    // Remove trailing slash
    if (std.mem.endsWith(u8, name, "/")) {
        name = name[0 .. name.len - 1];
    }

    // Remove .git suffix
    if (std.mem.endsWith(u8, name, ".git")) {
        name = name[0 .. name.len - 4];
    }

    // Get last component after /
    if (std.mem.lastIndexOf(u8, name, "/")) |pos| {
        name = name[pos + 1 ..];
    }

    return name;
}

test "extract repo name" {
    try std.testing.expectEqualStrings("repo", extractRepoName("https://github.com/user/repo.git"));
    try std.testing.expectEqualStrings("repo", extractRepoName("https://github.com/user/repo"));
    try std.testing.expectEqualStrings("repo", extractRepoName("https://github.com/user/repo/"));
}
