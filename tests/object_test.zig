// Object subsystem tests

const std = @import("std");
const object = @import("../src/object/mod.zig");

test "blob hash matches git" {
    const blob = object.Blob.init("hello\n");
    const sha = blob.computeHash();
    const hex = object.hash.toHex(sha);
    // echo "hello" | git hash-object --stdin
    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", &hex);
}

test "empty blob hash" {
    const blob = object.Blob.init("");
    const sha = blob.computeHash();
    const hex = object.hash.toHex(sha);
    // git hash-object -t blob /dev/null
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}

test "tree parse empty" {
    const allocator = std.testing.allocator;
    var tree = try object.tree.parse(allocator, "");
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), tree.entries.len);
}

test "commit parse minimal" {
    const allocator = std.testing.allocator;
    const data = "tree da39a3ee5e6b4b0d3255bfef95601890afd80709\n\nEmpty commit";
    var commit = try object.commit.parse(allocator, data);
    defer commit.deinit();
    try std.testing.expectEqual(@as(usize, 0), commit.parents.len);
    try std.testing.expectEqualStrings("Empty commit", commit.message);
}

test "commit with parent" {
    const allocator = std.testing.allocator;
    const data =
        \\tree da39a3ee5e6b4b0d3255bfef95601890afd80709
        \\parent f572d396fae9206628714fb2ce00f72e94f2258f
        \\author Test <test@test.com> 1234567890 +0000
        \\committer Test <test@test.com> 1234567890 +0000
        \\
        \\Test message
    ;
    var commit = try object.commit.parse(allocator, data);
    defer commit.deinit();
    try std.testing.expectEqual(@as(usize, 1), commit.parents.len);
    try std.testing.expectEqual(@as(i64, 1234567890), commit.author_time);
}

test "tag parse" {
    const allocator = std.testing.allocator;
    const data =
        \\object da39a3ee5e6b4b0d3255bfef95601890afd80709
        \\type commit
        \\tag v1.0.0
        \\tagger Test <test@test.com> 1234567890 +0000
        \\
        \\Release v1.0.0
    ;
    var tag = try object.tag.parse(allocator, data);
    defer tag.deinit();
    try std.testing.expectEqualStrings("v1.0.0", tag.tag_name);
    try std.testing.expectEqualStrings("commit", tag.obj_type);
}

test "sha1 known values" {
    // Empty string
    const empty = object.hash.hash("");
    const empty_hex = object.hash.toHex(empty);
    try std.testing.expectEqualStrings("da39a3ee5e6b4b0d3255bfef95601890afd80709", &empty_hex);

    // "hello\n"
    const hello = object.hash.hash("hello\n");
    const hello_hex = object.hash.toHex(hello);
    try std.testing.expectEqualStrings("f572d396fae9206628714fb2ce00f72e94f2258f", &hello_hex);
}

test "hex roundtrip" {
    const original = object.hash.hash("test data");
    const hex = object.hash.toHex(original);
    const recovered = try object.hash.fromHex(&hex);
    try std.testing.expectEqual(original, recovered);
}

test "invalid hex" {
    try std.testing.expectError(error.InvalidHexLength, object.hash.fromHex("abc"));
    try std.testing.expectError(error.InvalidHexChar, object.hash.fromHex("zz39a3ee5e6b4b0d3255bfef95601890afd80709"));
}
