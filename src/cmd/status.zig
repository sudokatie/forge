// forge status - show working tree status

const std = @import("std");
const object = @import("../object/mod.zig");
const index_mod = @import("../index/mod.zig");
const refs = @import("../refs/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    // Get branch name
    var ref_store = refs.RefStore.init(allocator, ".git");
    const head = ref_store.readHead() catch {
        try stdout.writeAll("On branch main\n\n");
        try stdout.writeAll("No commits yet\n\n");
        return;
    };

    switch (head) {
        .symbolic => |sym| {
            // Extract branch name from refs/heads/XXX
            const branch = if (std.mem.startsWith(u8, sym, "refs/heads/"))
                sym[11..]
            else
                sym;
            try stdout.writeAll("On branch ");
            try stdout.writeAll(branch);
            try stdout.writeAll("\n\n");
            allocator.free(sym);
        },
        .direct => |sha| {
            const hex = object.hash.toHex(sha);
            try stdout.writeAll("HEAD detached at ");
            try stdout.writeAll(hex[0..7]);
            try stdout.writeAll("\n\n");
        },
    }

    // Read index
    var idx = try index_mod.Index.read(allocator, ".git");
    defer idx.deinit();

    // Check for staged changes (in index but not in HEAD tree)
    // This is a simplified version - just list staged files
    if (idx.entries.len > 0) {
        try stdout.writeAll("Changes to be committed:\n");
        try stdout.writeAll("  (use \"forge restore --staged <file>...\" to unstage)\n\n");

        for (idx.entries) |entry| {
            try stdout.writeAll("\tnew file:   ");
            try stdout.writeAll(entry.path);
            try stdout.writeAll("\n");
        }
        try stdout.writeAll("\n");
    }

    // Check for untracked files
    const cwd = std.fs.cwd();
    var dir = cwd.openDir(".", .{ .iterate = true }) catch return;
    defer dir.close();

    var untracked: std.ArrayList([]const u8) = .empty;
    defer {
        for (untracked.items) |p| allocator.free(p);
        untracked.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;

        // Check if in index
        var in_index = false;
        for (idx.entries) |idx_entry| {
            if (std.mem.eql(u8, idx_entry.path, entry.name)) {
                in_index = true;
                break;
            }
        }

        if (!in_index) {
            try untracked.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    if (untracked.items.len > 0) {
        try stdout.writeAll("Untracked files:\n");
        try stdout.writeAll("  (use \"forge add <file>...\" to include in what will be committed)\n\n");

        for (untracked.items) |path| {
            try stdout.writeAll("\t");
            try stdout.writeAll(path);
            try stdout.writeAll("\n");
        }
        try stdout.writeAll("\n");
    }

    if (idx.entries.len == 0 and untracked.items.len == 0) {
        try stdout.writeAll("nothing to commit, working tree clean\n");
    }
}

test "status basic" {
    // Would need temp repo
}
