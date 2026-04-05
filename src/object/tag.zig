// Tag objects - annotated tags

const std = @import("std");
const hash_mod = @import("hash.zig");

pub const Tag = struct {
    object: hash_mod.Sha1, // Object being tagged (usually a commit)
    obj_type: []const u8, // Type of tagged object ("commit", "tree", etc.)
    tag_name: []const u8, // Tag name
    tagger: []const u8, // Tagger identity
    tagger_time: i64, // Timestamp
    tagger_tz: []const u8, // Timezone
    message: []const u8, // Tag message
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Tag) void {
        self.allocator.free(self.obj_type);
        self.allocator.free(self.tag_name);
        self.allocator.free(self.tagger);
        self.allocator.free(self.tagger_tz);
        self.allocator.free(self.message);
    }
};

/// Parse tag from raw object data
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Tag {
    var object_sha: ?hash_mod.Sha1 = null;
    var obj_type: ?[]const u8 = null;
    var tag_name: ?[]const u8 = null;
    var tagger: ?[]const u8 = null;
    var tagger_time: i64 = 0;
    var tagger_tz: ?[]const u8 = null;
    var message: []const u8 = "";

    var lines = std.mem.splitSequence(u8, data, "\n");
    var in_message = false;
    var message_start: usize = 0;

    var pos: usize = 0;
    while (lines.next()) |line| {
        pos += line.len + 1;

        if (in_message) {
            continue;
        }

        if (line.len == 0) {
            // Empty line marks start of message
            in_message = true;
            message_start = pos;
            continue;
        }

        if (std.mem.startsWith(u8, line, "object ")) {
            object_sha = hash_mod.fromHex(line[7..47]) catch null;
        } else if (std.mem.startsWith(u8, line, "type ")) {
            obj_type = try allocator.dupe(u8, line[5..]);
        } else if (std.mem.startsWith(u8, line, "tag ")) {
            tag_name = try allocator.dupe(u8, line[4..]);
        } else if (std.mem.startsWith(u8, line, "tagger ")) {
            const tagger_line = line[7..];
            // Format: Name <email> timestamp timezone
            // Find last space-separated parts for time and tz
            var last_space: usize = 0;
            var second_last_space: usize = 0;
            for (tagger_line, 0..) |c, i| {
                if (c == ' ') {
                    second_last_space = last_space;
                    last_space = i;
                }
            }

            if (last_space > 0 and second_last_space > 0) {
                tagger = try allocator.dupe(u8, tagger_line[0..second_last_space]);
                const time_str = tagger_line[second_last_space + 1 .. last_space];
                tagger_time = std.fmt.parseInt(i64, time_str, 10) catch 0;
                tagger_tz = try allocator.dupe(u8, tagger_line[last_space + 1 ..]);
            } else {
                tagger = try allocator.dupe(u8, tagger_line);
                tagger_tz = try allocator.dupe(u8, "+0000");
            }
        }
    }

    // Extract message
    if (message_start < data.len) {
        message = try allocator.dupe(u8, data[message_start..]);
    } else {
        message = try allocator.dupe(u8, "");
    }

    return Tag{
        .object = object_sha orelse return error.MissingObject,
        .obj_type = obj_type orelse try allocator.dupe(u8, "commit"),
        .tag_name = tag_name orelse return error.MissingTagName,
        .tagger = tagger orelse try allocator.dupe(u8, "Unknown"),
        .tagger_time = tagger_time,
        .tagger_tz = tagger_tz orelse try allocator.dupe(u8, "+0000"),
        .message = message,
        .allocator = allocator,
    };
}

/// Serialize tag for storage
pub fn serialize(allocator: std.mem.Allocator, t: Tag) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // Build content manually
    const hex = hash_mod.toHex(t.object);
    try result.appendSlice(allocator, "object ");
    try result.appendSlice(allocator, &hex);
    try result.appendSlice(allocator, "\n");

    try result.appendSlice(allocator, "type ");
    try result.appendSlice(allocator, t.obj_type);
    try result.appendSlice(allocator, "\n");

    try result.appendSlice(allocator, "tag ");
    try result.appendSlice(allocator, t.tag_name);
    try result.appendSlice(allocator, "\n");

    try result.appendSlice(allocator, "tagger ");
    try result.appendSlice(allocator, t.tagger);
    try result.appendSlice(allocator, " ");

    var time_buf: [32]u8 = undefined;
    const time_str = std.fmt.bufPrint(&time_buf, "{d}", .{t.tagger_time}) catch "0";
    try result.appendSlice(allocator, time_str);
    try result.appendSlice(allocator, " ");
    try result.appendSlice(allocator, t.tagger_tz);
    try result.appendSlice(allocator, "\n");

    try result.appendSlice(allocator, "\n");
    try result.appendSlice(allocator, t.message);

    return try result.toOwnedSlice(allocator);
}

test "parse tag" {
    const allocator = std.testing.allocator;

    const data =
        \\object a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
        \\type commit
        \\tag v1.0.0
        \\tagger Test User <test@example.com> 1234567890 +0000
        \\
        \\Initial release
        \\
    ;

    var t = try parse(allocator, data);
    defer t.deinit();

    try std.testing.expectEqualStrings("commit", t.obj_type);
    try std.testing.expectEqualStrings("v1.0.0", t.tag_name);
    try std.testing.expectEqual(@as(i64, 1234567890), t.tagger_time);
}

test "serialize tag" {
    const allocator = std.testing.allocator;

    var sha: hash_mod.Sha1 = undefined;
    @memset(&sha, 0xAB);

    const t = Tag{
        .object = sha,
        .obj_type = "commit",
        .tag_name = "v1.0.0",
        .tagger = "Test <test@example.com>",
        .tagger_time = 1234567890,
        .tagger_tz = "+0000",
        .message = "Release notes\n",
        .allocator = allocator,
    };

    const serialized = try serialize(allocator, t);
    defer allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "tag v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "Release notes") != null);
}
