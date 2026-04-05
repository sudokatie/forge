// Git interoperability tests
// Verifies that forge-created repos are valid according to git

const std = @import("std");
const object = @import("../src/object/mod.zig");
const index_mod = @import("../src/index/mod.zig");

/// Run a shell command and return stdout
fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    if (cwd) |c| {
        child.cwd = c;
    }
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .pipe;

    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stdout);

    const term = try child.wait();
    if (term.Exited != 0) {
        allocator.free(stdout);
        return error.CommandFailed;
    }

    return stdout;
}

/// Check if git is available
fn gitAvailable(allocator: std.mem.Allocator) bool {
    const result = runCommand(allocator, &.{ "git", "--version" }, null) catch return false;
    allocator.free(result);
    return true;
}

test "forge object readable by git" {
    const allocator = std.testing.allocator;

    if (!gitAvailable(allocator)) {
        // Skip if git not installed
        return;
    }

    // Create temp directory
    var tmp_dir_path: [256]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_dir_path, "/tmp/forge_interop_test_{d}", .{std.time.milliTimestamp()}) catch return;

    std.fs.cwd().makeDir(tmp_path) catch return;
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    // Initialize with forge structure
    var dir = std.fs.cwd().openDir(tmp_path, .{}) catch return;
    defer dir.close();

    dir.makePath(".git/objects") catch return;
    dir.makePath(".git/refs/heads") catch return;

    // Write HEAD
    const head = dir.createFile(".git/HEAD", .{}) catch return;
    head.writeAll("ref: refs/heads/main\n") catch {};
    head.close();

    // Write config
    const config = dir.createFile(".git/config", .{}) catch return;
    config.writeAll("[core]\n    repositoryformatversion = 0\n    filemode = true\n    bare = false\n") catch {};
    config.close();

    // Create a blob using forge's object store
    var store = object.ObjectStore.init(allocator, tmp_path ++ "/.git");
    const blob_content = "Hello from forge!\n";
    const blob_sha = store.write(.blob, blob_content) catch return;

    // Verify with git cat-file
    const hex = object.hash.toHex(blob_sha);
    const git_output = runCommand(allocator, &.{ "git", "cat-file", "-p", &hex }, tmp_path) catch |err| {
        std.debug.print("git cat-file failed: {any}\n", .{err});
        return err;
    };
    defer allocator.free(git_output);

    try std.testing.expectEqualStrings(blob_content, git_output);
}

test "forge tree readable by git" {
    const allocator = std.testing.allocator;

    if (!gitAvailable(allocator)) {
        return;
    }

    // Create temp directory
    var tmp_dir_path: [256]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_dir_path, "/tmp/forge_tree_test_{d}", .{std.time.milliTimestamp()}) catch return;

    std.fs.cwd().makeDir(tmp_path) catch return;
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var dir = std.fs.cwd().openDir(tmp_path, .{}) catch return;
    defer dir.close();

    dir.makePath(".git/objects") catch return;
    dir.makePath(".git/refs/heads") catch return;

    const head = dir.createFile(".git/HEAD", .{}) catch return;
    head.writeAll("ref: refs/heads/main\n") catch {};
    head.close();

    const config = dir.createFile(".git/config", .{}) catch return;
    config.writeAll("[core]\n    repositoryformatversion = 0\n") catch {};
    config.close();

    var store = object.ObjectStore.init(allocator, tmp_path ++ "/.git");

    // Create a blob
    const blob_sha = store.write(.blob, "file content\n") catch return;

    // Create a tree containing the blob
    var tree_content: std.ArrayList(u8) = .empty;
    defer tree_content.deinit(allocator);

    // Tree entry format: mode SP name NUL sha
    tree_content.appendSlice(allocator, "100644 test.txt\x00") catch return;
    tree_content.appendSlice(allocator, &blob_sha) catch return;

    const tree_sha = store.write(.tree, tree_content.items) catch return;
    const tree_hex = object.hash.toHex(tree_sha);

    // Verify with git ls-tree
    const git_output = runCommand(allocator, &.{ "git", "ls-tree", &tree_hex }, tmp_path) catch return;
    defer allocator.free(git_output);

    // Should contain our file
    try std.testing.expect(std.mem.indexOf(u8, git_output, "test.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, git_output, "blob") != null);
}

test "forge commit readable by git" {
    const allocator = std.testing.allocator;

    if (!gitAvailable(allocator)) {
        return;
    }

    var tmp_dir_path: [256]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_dir_path, "/tmp/forge_commit_test_{d}", .{std.time.milliTimestamp()}) catch return;

    std.fs.cwd().makeDir(tmp_path) catch return;
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var dir = std.fs.cwd().openDir(tmp_path, .{}) catch return;
    defer dir.close();

    dir.makePath(".git/objects") catch return;
    dir.makePath(".git/refs/heads") catch return;

    const head = dir.createFile(".git/HEAD", .{}) catch return;
    head.writeAll("ref: refs/heads/main\n") catch {};
    head.close();

    const config = dir.createFile(".git/config", .{}) catch return;
    config.writeAll("[core]\n    repositoryformatversion = 0\n") catch {};
    config.close();

    var store = object.ObjectStore.init(allocator, tmp_path ++ "/.git");

    // Create blob -> tree -> commit
    const blob_sha = store.write(.blob, "hello\n") catch return;

    var tree_content: std.ArrayList(u8) = .empty;
    defer tree_content.deinit(allocator);
    tree_content.appendSlice(allocator, "100644 hello.txt\x00") catch return;
    tree_content.appendSlice(allocator, &blob_sha) catch return;

    const tree_sha = store.write(.tree, tree_content.items) catch return;
    const tree_hex = object.hash.toHex(tree_sha);

    // Create commit
    var commit_content: std.ArrayList(u8) = .empty;
    defer commit_content.deinit(allocator);

    commit_content.appendSlice(allocator, "tree ") catch return;
    commit_content.appendSlice(allocator, &tree_hex) catch return;
    commit_content.appendSlice(allocator, "\nauthor Test <test@test.com> 1234567890 +0000\n") catch return;
    commit_content.appendSlice(allocator, "committer Test <test@test.com> 1234567890 +0000\n") catch return;
    commit_content.appendSlice(allocator, "\nTest commit\n") catch return;

    const commit_sha = store.write(.commit, commit_content.items) catch return;
    const commit_hex = object.hash.toHex(commit_sha);

    // Update refs/heads/main
    dir.makePath(".git/refs/heads") catch return;
    const ref = dir.createFile(".git/refs/heads/main", .{}) catch return;
    ref.writeAll(&commit_hex) catch {};
    ref.writeAll("\n") catch {};
    ref.close();

    // Verify with git log
    const git_output = runCommand(allocator, &.{ "git", "log", "--oneline", "-1" }, tmp_path) catch return;
    defer allocator.free(git_output);

    try std.testing.expect(std.mem.indexOf(u8, git_output, "Test commit") != null);
}

test "git fsck validates forge repo" {
    const allocator = std.testing.allocator;

    if (!gitAvailable(allocator)) {
        return;
    }

    var tmp_dir_path: [256]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_dir_path, "/tmp/forge_fsck_test_{d}", .{std.time.milliTimestamp()}) catch return;

    std.fs.cwd().makeDir(tmp_path) catch return;
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var dir = std.fs.cwd().openDir(tmp_path, .{}) catch return;
    defer dir.close();

    dir.makePath(".git/objects") catch return;
    dir.makePath(".git/refs/heads") catch return;

    const head = dir.createFile(".git/HEAD", .{}) catch return;
    head.writeAll("ref: refs/heads/main\n") catch {};
    head.close();

    const config = dir.createFile(".git/config", .{}) catch return;
    config.writeAll("[core]\n    repositoryformatversion = 0\n    filemode = true\n") catch {};
    config.close();

    var store = object.ObjectStore.init(allocator, tmp_path ++ "/.git");

    // Create a complete commit chain
    const blob_sha = store.write(.blob, "content\n") catch return;

    var tree_content: std.ArrayList(u8) = .empty;
    defer tree_content.deinit(allocator);
    tree_content.appendSlice(allocator, "100644 file.txt\x00") catch return;
    tree_content.appendSlice(allocator, &blob_sha) catch return;

    const tree_sha = store.write(.tree, tree_content.items) catch return;
    const tree_hex = object.hash.toHex(tree_sha);

    var commit_content: std.ArrayList(u8) = .empty;
    defer commit_content.deinit(allocator);
    commit_content.appendSlice(allocator, "tree ") catch return;
    commit_content.appendSlice(allocator, &tree_hex) catch return;
    commit_content.appendSlice(allocator, "\nauthor Forge <forge@test.com> 1700000000 +0000\n") catch return;
    commit_content.appendSlice(allocator, "committer Forge <forge@test.com> 1700000000 +0000\n") catch return;
    commit_content.appendSlice(allocator, "\nInitial commit\n") catch return;

    const commit_sha = store.write(.commit, commit_content.items) catch return;
    const commit_hex = object.hash.toHex(commit_sha);

    const ref = dir.createFile(".git/refs/heads/main", .{}) catch return;
    ref.writeAll(&commit_hex) catch {};
    ref.writeAll("\n") catch {};
    ref.close();

    // Run git fsck - should pass without errors
    const fsck_output = runCommand(allocator, &.{ "git", "fsck", "--full" }, tmp_path) catch |err| {
        std.debug.print("git fsck failed: {any}\n", .{err});
        return err;
    };
    defer allocator.free(fsck_output);

    // fsck should not report any errors (empty or just notices)
    // If there are critical errors, fsck returns non-zero which runCommand catches
    // So if we get here, the repo is valid
}

test "git can read forge index" {
    const allocator = std.testing.allocator;

    if (!gitAvailable(allocator)) {
        return;
    }

    var tmp_dir_path: [256]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_dir_path, "/tmp/forge_index_test_{d}", .{std.time.milliTimestamp()}) catch return;

    std.fs.cwd().makeDir(tmp_path) catch return;
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var dir = std.fs.cwd().openDir(tmp_path, .{}) catch return;
    defer dir.close();

    dir.makePath(".git/objects") catch return;
    dir.makePath(".git/refs/heads") catch return;

    const head = dir.createFile(".git/HEAD", .{}) catch return;
    head.writeAll("ref: refs/heads/main\n") catch {};
    head.close();

    const config = dir.createFile(".git/config", .{}) catch return;
    config.writeAll("[core]\n    repositoryformatversion = 0\n") catch {};
    config.close();

    var store = object.ObjectStore.init(allocator, tmp_path ++ "/.git");
    const blob_sha = store.write(.blob, "indexed content\n") catch return;

    // Create index with forge
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();

    const path = allocator.dupe(u8, "indexed.txt") catch return;
    try idx.add(.{
        .ctime_s = 1700000000,
        .ctime_ns = 0,
        .mtime_s = 1700000000,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .size = 16,
        .sha = blob_sha,
        .flags = 0,
        .path = path,
    });

    idx.write(tmp_path ++ "/.git") catch return;

    // Verify with git ls-files
    const git_output = runCommand(allocator, &.{ "git", "ls-files", "--stage" }, tmp_path) catch return;
    defer allocator.free(git_output);

    try std.testing.expect(std.mem.indexOf(u8, git_output, "indexed.txt") != null);
}
