// forge add - stage files for commit

const std = @import("std");
const object = @import("../object/mod.zig");
const index_mod = @import("../index/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    if (args.len == 0) {
        try stderr.writeAll("Nothing specified, nothing added.\n");
        return;
    }

    // Read existing index
    var idx = try index_mod.Index.read(allocator, ".git");
    defer idx.deinit();

    var store = object.ObjectStore.init(allocator, ".git");

    for (args) |path| {
        try addFile(allocator, &idx, &store, path);
    }

    // Write updated index
    try idx.write(".git");
}

fn addFile(allocator: std.mem.Allocator, idx: *index_mod.Index, store: *object.ObjectStore, path: []const u8) !void {
    const cwd = std.fs.cwd();

    // Read file content
    const content = cwd.readFileAlloc(allocator, path, 100 * 1024 * 1024) catch |err| {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: pathspec '{s}' did not match any files\n", .{path}) catch {
            try stderr.writeAll("fatal: file not found\n");
            return err;
        };
        try stderr.writeAll(msg);
        return err;
    };
    defer allocator.free(content);

    // Get file stat
    const stat = cwd.statFile(path) catch |err| {
        return err;
    };

    // Write blob to object store
    const sha = try store.write(.blob, content);

    // Add to index
    try idx.add(.{
        .ctime_s = @intCast(@divTrunc(stat.ctime, std.time.ns_per_s)),
        .ctime_ns = @intCast(@mod(stat.ctime, std.time.ns_per_s)),
        .mtime_s = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s)),
        .mtime_ns = @intCast(@mod(stat.mtime, std.time.ns_per_s)),
        .dev = 0,
        .ino = 0,
        .mode = 0o100644, // Regular file
        .uid = 0,
        .gid = 0,
        .size = @intCast(stat.size),
        .sha = sha,
        .flags = 0,
        .path = try allocator.dupe(u8, path),
    });
}

test "add file basic" {
    // Would need temp directory with git init
}
