// Integration tests - full workflow validation

const std = @import("std");
const object = @import("object/mod.zig");
const refs = @import("refs/mod.zig");
const index = @import("index/mod.zig");
const pack = @import("pack/mod.zig");
const protocol = @import("protocol/mod.zig");
const diff_mod = @import("diff/mod.zig");

// Test object creation and retrieval
test "object roundtrip" {
    // Create blob
    const content = "Hello, Forge!";
    const blob = object.Blob.init(content);
    const sha = blob.computeHash();

    // Verify hash is deterministic
    const sha2 = object.hash.hash("blob 13\x00Hello, Forge!");
    try std.testing.expectEqual(sha, sha2);
}

// Test tree parsing
test "tree structure" {
    const allocator = std.testing.allocator;

    // Build a tree entry manually
    const sha = object.hash.hash("test content");

    var tree = object.Tree{
        .entries = &.{},
        .allocator = allocator,
    };
    defer tree.deinit();

    // Tree should be empty initially
    try std.testing.expectEqual(@as(usize, 0), tree.entries.len);
    _ = sha;
}

// Test commit parsing with parents
test "commit with parents" {
    const allocator = std.testing.allocator;

    const commit_data =
        \\tree da39a3ee5e6b4b0d3255bfef95601890afd80709
        \\parent f572d396fae9206628714fb2ce00f72e94f2258f
        \\author Test User <test@example.com> 1000000000 +0000
        \\committer Test User <test@example.com> 1000000000 +0000
        \\
        \\Test commit message
    ;

    var commit = try object.commit.parse(allocator, commit_data);
    defer commit.deinit();

    try std.testing.expectEqual(@as(usize, 1), commit.parents.len);
    try std.testing.expectEqual(@as(i64, 1000000000), commit.author_time);
    try std.testing.expectEqualStrings("+0000", commit.author_tz);
}

// Test index entry serialization
test "index entry roundtrip" {
    const allocator = std.testing.allocator;

    const sha = object.hash.hash("test file content");

    var idx = index.Index.init(allocator);
    defer idx.deinit();

    try idx.add(.{
        .ctime_s = 1000,
        .ctime_ns = 0,
        .mtime_s = 2000,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .size = 17,
        .sha = sha,
        .flags = 0,
        .path = try allocator.dupe(u8, "test.txt"),
    });

    try std.testing.expectEqual(@as(usize, 1), idx.entries.len);
    try std.testing.expectEqualStrings("test.txt", idx.entries[0].path);
}

// Test diff algorithm
test "diff basic changes" {
    const allocator = std.testing.allocator;

    const old_text = "line1\nline2\nline3";
    const new_text = "line1\nmodified\nline3";

    const edits = try diff_mod.diff(allocator, old_text, new_text);
    defer allocator.free(edits);

    try std.testing.expect(edits.len > 0);
}

// Test pack delta encoding
test "delta apply" {
    const allocator = std.testing.allocator;

    // Simple insert delta
    const base = "hello";
    var delta: [20]u8 = undefined;
    var pos: usize = 0;

    // Base size = 5
    delta[pos] = 5;
    pos += 1;
    // Result size = 11
    delta[pos] = 11;
    pos += 1;
    // Copy base (0x80 | 0x01 | 0x10)
    delta[pos] = 0x91;
    pos += 1;
    delta[pos] = 0; // offset
    pos += 1;
    delta[pos] = 5; // size
    pos += 1;
    // Insert " world"
    delta[pos] = 6;
    pos += 1;
    @memcpy(delta[pos .. pos + 6], " world");
    pos += 6;

    const result = try pack.applyDelta(allocator, base, delta[0..pos]);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello world", result);
}

// Test pktline encoding
test "pktline roundtrip" {
    const allocator = std.testing.allocator;

    const encoded = try protocol.encode(allocator, "test data");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("000dtest data", encoded);

    var decoder = protocol.Decoder.init(encoded);
    const decoded = try decoder.next();
    try std.testing.expect(decoded != null);
    try std.testing.expectEqualStrings("test data", decoded.?);
}

// Test SHA-1 hashing
test "sha1 known values" {
    // Empty string
    const empty_sha = object.hash.hash("");
    const empty_hex = object.hash.toHex(empty_sha);
    try std.testing.expectEqualStrings("da39a3ee5e6b4b0d3255bfef95601890afd80709", &empty_hex);

    // "hello\n"
    const hello_sha = object.hash.hash("hello\n");
    const hello_hex = object.hash.toHex(hello_sha);
    try std.testing.expectEqualStrings("f572d396fae9206628714fb2ce00f72e94f2258f", &hello_hex);
}

// Test hex conversion roundtrip
test "hex roundtrip" {
    const original = object.hash.hash("test data");
    const hex = object.hash.toHex(original);
    const recovered = try object.hash.fromHex(&hex);
    try std.testing.expectEqual(original, recovered);
}
