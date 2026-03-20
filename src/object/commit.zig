// Commit objects

const std = @import("std");
const hash_mod = @import("hash.zig");

pub const Commit = struct {
    tree: hash_mod.Sha1,
    parents: []hash_mod.Sha1,
    author: []const u8,
    author_time: i64,
    author_tz: []const u8,
    committer: []const u8,
    committer_time: i64,
    committer_tz: []const u8,
    message: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Commit) void {
        self.allocator.free(self.parents);
    }
};

/// Parse commit from raw object data
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Commit {
    var tree: hash_mod.Sha1 = undefined;
    var parents: std.ArrayList(hash_mod.Sha1) = .empty;
    errdefer parents.deinit(allocator);

    var author: []const u8 = "";
    const author_time: i64 = 0;
    const author_tz: []const u8 = "";
    var committer: []const u8 = "";
    const committer_time: i64 = 0;
    const committer_tz: []const u8 = "";
    var message: []const u8 = "";

    var lines = std.mem.splitSequence(u8, data, "\n");
    var in_message = false;
    var message_start: usize = 0;

    while (lines.next()) |line| {
        if (in_message) {
            continue;
        }

        if (line.len == 0) {
            in_message = true;
            message_start = lines.index orelse data.len;
            message = data[message_start..];
            break;
        }

        if (std.mem.startsWith(u8, line, "tree ")) {
            tree = try hash_mod.fromHex(line[5..45]);
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            const parent = try hash_mod.fromHex(line[7..47]);
            try parents.append(allocator, parent);
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author = line[7..];
            // TODO: parse timestamp
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            committer = line[10..];
            // TODO: parse timestamp
        }
    }

    return Commit{
        .tree = tree,
        .parents = try parents.toOwnedSlice(allocator),
        .author = author,
        .author_time = author_time,
        .author_tz = author_tz,
        .committer = committer,
        .committer_time = committer_time,
        .committer_tz = committer_tz,
        .message = message,
        .allocator = allocator,
    };
}

/// Serialize commit for storage
pub fn serialize(allocator: std.mem.Allocator, commit: Commit) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    const writer = result.writer(allocator);
    try writer.print("tree {s}\n", .{hash_mod.toHex(commit.tree)});

    for (commit.parents) |parent| {
        try writer.print("parent {s}\n", .{hash_mod.toHex(parent)});
    }

    try writer.print("author {s}\n", .{commit.author});
    try writer.print("committer {s}\n", .{commit.committer});
    try writer.print("\n{s}", .{commit.message});

    return try result.toOwnedSlice(allocator);
}

test "commit parse empty" {
    const allocator = std.testing.allocator;
    var commit = try parse(allocator, "tree da39a3ee5e6b4b0d3255bfef95601890afd80709\n\ntest message");
    defer commit.deinit();

    try std.testing.expectEqual(@as(usize, 0), commit.parents.len);
    try std.testing.expectEqualStrings("test message", commit.message);
}
