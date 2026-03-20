// forge init - create empty repository

const std = @import("std");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;

    const cwd = std.fs.cwd();

    // Create .git directory structure
    try cwd.makePath(".git/objects");
    try cwd.makePath(".git/refs/heads");
    try cwd.makePath(".git/refs/tags");

    // Create HEAD
    const head = try cwd.createFile(".git/HEAD", .{});
    defer head.close();
    try head.writeAll("ref: refs/heads/main\n");

    // Create config
    const config = try cwd.createFile(".git/config", .{});
    defer config.close();
    try config.writeAll("[core]\n    repositoryformatversion = 0\n    filemode = true\n    bare = false\n");

    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const abs_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(abs_path);

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Initialized empty Forge repository in {s}/.git/\n", .{abs_path}) catch {
        try stdout.writeAll("Initialized empty Forge repository\n");
        return;
    };
    try stdout.writeAll(msg);
}

test "init creates structure" {
    const allocator = std.testing.allocator;

    // Create temp directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Save current directory and change to temp
    const old_cwd = std.fs.cwd();
    tmp_dir.dir.setAsCwd() catch return;
    defer old_cwd.setAsCwd() catch {};

    // Run init
    try run(allocator, &.{});

    // Verify structure
    tmp_dir.dir.access(".git/objects", .{}) catch return error.ObjectsDirMissing;
    tmp_dir.dir.access(".git/refs/heads", .{}) catch return error.RefsDirMissing;
    tmp_dir.dir.access(".git/HEAD", .{}) catch return error.HeadMissing;
    tmp_dir.dir.access(".git/config", .{}) catch return error.ConfigMissing;

    // Verify HEAD content
    const head = try tmp_dir.dir.readFileAlloc(allocator, ".git/HEAD", 1024);
    defer allocator.free(head);
    try std.testing.expectEqualStrings("ref: refs/heads/main\n", head);
}
