// Tree objects - directory listings

const std = @import("std");
const hash_mod = @import("hash.zig");

pub const TreeEntry = struct {
    mode: u32,
    name: []const u8,
    sha: hash_mod.Sha1,
};

pub const Tree = struct {
    entries: []TreeEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Tree) void {
        self.allocator.free(self.entries);
    }
};

/// Parse tree from raw object data
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Tree {
    var entries = std.ArrayList(TreeEntry).init(allocator);
    errdefer entries.deinit();

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

        try entries.append(.{
            .mode = mode,
            .name = name,
            .sha = sha,
        });
    }

    return Tree{
        .entries = try entries.toOwnedSlice(),
        .allocator = allocator,
    };
}

/// Serialize tree for storage
pub fn serialize(allocator: std.mem.Allocator, tree: Tree) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    for (tree.entries) |entry| {
        try result.writer().print("{o} {s}\x00", .{ entry.mode, entry.name });
        try result.appendSlice(&entry.sha);
    }

    return try result.toOwnedSlice();
}

test "tree parse" {
    // Simple test with mocked data
    const allocator = std.testing.allocator;
    var tree = try parse(allocator, "");
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), tree.entries.len);
}
