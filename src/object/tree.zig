// Tree objects - directory listings

const std = @import("std");
const hash_mod = @import("hash.zig");
const store_mod = @import("store.zig");

pub const TreeEntry = struct {
    mode: u32,
    name: []const u8,
    sha: hash_mod.Sha1,
};

// Alias for compatibility
pub const Entry = TreeEntry;

pub const Tree = struct {
    entries: []TreeEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Tree) void {
        self.allocator.free(self.entries);
    }
};

/// Parse tree from raw object data
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Tree {
    var entries: std.ArrayList(TreeEntry) = .empty;
    errdefer entries.deinit(allocator);

    var pos: usize = 0;
    while (pos < data.len) {
        // Format: <mode> <name>\0<20-byte sha>
        const space = std.mem.indexOf(u8, data[pos..], " ") orelse break;
        const mode_str = data[pos .. pos + space];
        const mode = std.fmt.parseInt(u32, mode_str, 8) catch break;

        pos += space + 1;
        const null_pos = std.mem.indexOf(u8, data[pos..], "\x00") orelse break;
        const name = data[pos .. pos + null_pos];

        pos += null_pos + 1;
        if (pos + 20 > data.len) break;

        var sha: hash_mod.Sha1 = undefined;
        @memcpy(&sha, data[pos .. pos + 20]);
        pos += 20;

        try entries.append(allocator, .{
            .mode = mode,
            .name = name,
            .sha = sha,
        });
    }

    return Tree{
        .entries = try entries.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Serialize tree for storage
pub fn serialize(allocator: std.mem.Allocator, tree: Tree) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (tree.entries) |entry| {
        try result.writer(allocator).print("{o} {s}\x00", .{ entry.mode, entry.name });
        try result.appendSlice(allocator, &entry.sha);
    }

    return try result.toOwnedSlice(allocator);
}

/// Serialize entries for storage
pub fn serializeEntries(allocator: std.mem.Allocator, entries: []const TreeEntry) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (entries) |entry| {
        try result.writer(allocator).print("{o} {s}\x00", .{ entry.mode, entry.name });
        try result.appendSlice(allocator, &entry.sha);
    }

    return try result.toOwnedSlice(allocator);
}

/// Write a tree object to the store and return its hash
pub fn writeTree(
    allocator: std.mem.Allocator,
    store: *store_mod.ObjectStore,
    entries: []const TreeEntry,
) !hash_mod.Sha1 {
    const content = try serializeEntries(allocator, entries);
    defer allocator.free(content);

    return try store.write(allocator, store_mod.ObjectType.tree, content);
}

test "tree parse" {
    // Simple test with mocked data
    const allocator = std.testing.allocator;
    var tree = try parse(allocator, "");
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), tree.entries.len);
}
