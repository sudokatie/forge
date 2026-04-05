// forge hash-object - compute object ID and optionally write

const std = @import("std");
const object = @import("../object/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var write_object = false;
    var stdin_mode = false;
    var obj_type: object.ObjectType = .blob;
    var file_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-w")) {
            write_object = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
            i += 1;
            const type_str = args[i];
            if (std.mem.eql(u8, type_str, "blob")) {
                obj_type = .blob;
            } else if (std.mem.eql(u8, type_str, "tree")) {
                obj_type = .tree;
            } else if (std.mem.eql(u8, type_str, "commit")) {
                obj_type = .commit;
            } else if (std.mem.eql(u8, type_str, "tag")) {
                obj_type = .tag;
            } else {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: invalid object type '{s}'\n", .{type_str}) catch "fatal: invalid object type\n";
                try stderr.writeAll(msg);
                return;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
        }
    }

    // Read content
    var content: []u8 = undefined;
    if (stdin_mode) {
        const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
        content = try stdin.readToEndAlloc(allocator, 100 * 1024 * 1024);
    } else if (file_path) |path| {
        content = std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: could not read file '{s}': {any}\n", .{ path, err }) catch "fatal: could not read file\n";
            try stderr.writeAll(msg);
            return;
        };
    } else {
        try stderr.writeAll("usage: forge hash-object [-w] [-t <type>] [--stdin | <file>]\n");
        return;
    }
    defer allocator.free(content);

    // Compute hash
    const type_str = switch (obj_type) {
        .blob => "blob",
        .tree => "tree",
        .commit => "commit",
        .tag => "tag",
    };

    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} {d}\x00", .{ type_str, content.len }) catch unreachable;

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(content);
    const sha = hasher.finalResult();

    // Optionally write to object store
    if (write_object) {
        var store = object.ObjectStore.init(allocator, ".git");
        _ = try store.write(obj_type, content);
    }

    // Print hash
    const hex = object.hash.toHex(sha);
    try stdout.writeAll(&hex);
    try stdout.writeAll("\n");
}

test "hash-object computes correct hash" {
    const content = "hello\n";
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "blob {d}\x00", .{content.len}) catch unreachable;

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(content);
    const sha = hasher.finalResult();
    const hex = @import("../object/hash.zig").toHex(sha);

    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", &hex);
}
