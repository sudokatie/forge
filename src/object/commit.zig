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

/// Parse author/committer line: "Name <email> timestamp tz"
fn parseIdentity(line: []const u8) struct { name: []const u8, time: i64, tz: []const u8 } {
    // Find timestamp by looking for last two space-separated tokens
    var last_space: ?usize = null;
    var second_last: ?usize = null;

    var i: usize = line.len;
    while (i > 0) {
        i -= 1;
        if (line[i] == ' ') {
            if (last_space == null) {
                last_space = i;
            } else {
                second_last = i;
                break;
            }
        }
    }

    if (second_last) |ts_start| {
        const name = line[0..ts_start];
        const ts_str = line[ts_start + 1 .. last_space.?];
        const tz = line[last_space.? + 1 ..];
        const time = std.fmt.parseInt(i64, ts_str, 10) catch 0;
        return .{ .name = name, .time = time, .tz = tz };
    }

    return .{ .name = line, .time = 0, .tz = "" };
}

/// Parse commit from raw object data
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Commit {
    var tree: hash_mod.Sha1 = undefined;
    var parents: std.ArrayList(hash_mod.Sha1) = .empty;
    errdefer parents.deinit(allocator);

    var author: []const u8 = "";
    var author_time: i64 = 0;
    var author_tz: []const u8 = "";
    var committer: []const u8 = "";
    var committer_time: i64 = 0;
    var committer_tz: []const u8 = "";
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
            const id = parseIdentity(line[7..]);
            author = id.name;
            author_time = id.time;
            author_tz = id.tz;
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            const id = parseIdentity(line[10..]);
            committer = id.name;
            committer_time = id.time;
            committer_tz = id.tz;
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

    try writer.print("author {s} {d} {s}\n", .{ commit.author, commit.author_time, commit.author_tz });
    try writer.print("committer {s} {d} {s}\n", .{ commit.committer, commit.committer_time, commit.committer_tz });
    try writer.print("\n{s}", .{commit.message});

    return try result.toOwnedSlice(allocator);
}

test "commit parse no parents" {
    const allocator = std.testing.allocator;
    var commit = try parse(allocator, "tree da39a3ee5e6b4b0d3255bfef95601890afd80709\n\ntest message");
    defer commit.deinit();

    try std.testing.expectEqual(@as(usize, 0), commit.parents.len);
    try std.testing.expectEqualStrings("test message", commit.message);
}

test "commit parse with author timestamp" {
    const allocator = std.testing.allocator;
    const data =
        \\tree da39a3ee5e6b4b0d3255bfef95601890afd80709
        \\author John Doe <john@example.com> 1234567890 +0000
        \\committer Jane Doe <jane@example.com> 1234567900 -0500
        \\
        \\Initial commit
    ;
    var commit = try parse(allocator, data);
    defer commit.deinit();

    try std.testing.expectEqual(@as(i64, 1234567890), commit.author_time);
    try std.testing.expectEqualStrings("+0000", commit.author_tz);
    try std.testing.expectEqual(@as(i64, 1234567900), commit.committer_time);
    try std.testing.expectEqualStrings("-0500", commit.committer_tz);
}

test "commit parse with parents" {
    const allocator = std.testing.allocator;
    const data =
        \\tree da39a3ee5e6b4b0d3255bfef95601890afd80709
        \\parent f572d396fae9206628714fb2ce00f72e94f2258f
        \\parent ce013625030ba8dba906f756967f9e9ca394464a
        \\author Test <test@test.com> 1000 +0000
        \\committer Test <test@test.com> 1000 +0000
        \\
        \\Merge commit
    ;
    var commit = try parse(allocator, data);
    defer commit.deinit();

    try std.testing.expectEqual(@as(usize, 2), commit.parents.len);
    try std.testing.expectEqualStrings("Merge commit", commit.message);
}
