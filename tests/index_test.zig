// Index subsystem tests

const std = @import("std");
const index = @import("../src/index/mod.zig");
const object = @import("../src/object/mod.zig");

test "empty index" {
    const allocator = std.testing.allocator;
    var idx = index.Index.init(allocator);
    defer idx.deinit();
    try std.testing.expectEqual(@as(usize, 0), idx.entries.len);
}

test "index header parse v2" {
    var data: [32]u8 = undefined;
    @memcpy(data[0..4], "DIRC");
    std.mem.writeInt(u32, data[4..8], 2, .big);
    std.mem.writeInt(u32, data[8..12], 0, .big);
    @memset(data[12..], 0);

    const allocator = std.testing.allocator;
    var idx = try index.Index.parse(allocator, &data);
    defer idx.deinit();

    try std.testing.expectEqual(@as(usize, 0), idx.entries.len);
    try std.testing.expectEqual(@as(u32, 2), idx.version);
}

test "index add entry" {
    const allocator = std.testing.allocator;
    var idx = index.Index.init(allocator);
    defer idx.deinit();

    const sha = object.hash.hash("test content");
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
        .size = 12,
        .sha = sha,
        .flags = 0,
        .path = try allocator.dupe(u8, "test.txt"),
    });

    try std.testing.expectEqual(@as(usize, 1), idx.entries.len);
    try std.testing.expectEqualStrings("test.txt", idx.entries[0].path);
}

test "index add sorted" {
    const allocator = std.testing.allocator;
    var idx = index.Index.init(allocator);
    defer idx.deinit();

    const sha = object.hash.hash("test");

    // Add out of order
    try idx.add(.{
        .ctime_s = 0,
        .ctime_ns = 0,
        .mtime_s = 0,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .sha = sha,
        .flags = 0,
        .path = try allocator.dupe(u8, "c.txt"),
    });
    try idx.add(.{
        .ctime_s = 0,
        .ctime_ns = 0,
        .mtime_s = 0,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .sha = sha,
        .flags = 0,
        .path = try allocator.dupe(u8, "a.txt"),
    });
    try idx.add(.{
        .ctime_s = 0,
        .ctime_ns = 0,
        .mtime_s = 0,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .sha = sha,
        .flags = 0,
        .path = try allocator.dupe(u8, "b.txt"),
    });

    // Should be sorted
    try std.testing.expectEqualStrings("a.txt", idx.entries[0].path);
    try std.testing.expectEqualStrings("b.txt", idx.entries[1].path);
    try std.testing.expectEqualStrings("c.txt", idx.entries[2].path);
}

test "index remove entry" {
    const allocator = std.testing.allocator;
    var idx = index.Index.init(allocator);
    defer idx.deinit();

    const sha = object.hash.hash("test");
    try idx.add(.{
        .ctime_s = 0,
        .ctime_ns = 0,
        .mtime_s = 0,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .sha = sha,
        .flags = 0,
        .path = try allocator.dupe(u8, "test.txt"),
    });

    try std.testing.expectEqual(@as(usize, 1), idx.entries.len);

    const removed = idx.remove("test.txt");
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 0), idx.entries.len);
}

test "entry serialize roundtrip" {
    const allocator = std.testing.allocator;

    const sha = object.hash.hash("content");
    const original = index.IndexEntry{
        .ctime_s = 1000,
        .ctime_ns = 500,
        .mtime_s = 2000,
        .mtime_ns = 600,
        .dev = 1,
        .ino = 12345,
        .mode = 0o100644,
        .uid = 1000,
        .gid = 1000,
        .size = 42,
        .sha = sha,
        .flags = 0,
        .path = "test.txt",
    };

    const serialized = try original.serialize(allocator, 2);
    defer allocator.free(serialized);

    const parsed = try index.IndexEntry.parse(allocator, serialized, 2);
    defer allocator.free(parsed.entry.path);

    try std.testing.expectEqual(original.ctime_s, parsed.entry.ctime_s);
    try std.testing.expectEqual(original.mtime_s, parsed.entry.mtime_s);
    try std.testing.expectEqual(original.mode, parsed.entry.mode);
    try std.testing.expectEqualStrings(original.path, parsed.entry.path);
}

test "tree cache parse" {
    const allocator = std.testing.allocator;

    // Empty tree cache
    var tc = try index.TreeCache.parse(allocator, "");
    defer tc.deinit();
    try std.testing.expectEqual(@as(usize, 0), tc.entries.len);
}

test "tree cache invalidate" {
    const allocator = std.testing.allocator;

    var tc = index.TreeCache.init(allocator);
    defer tc.deinit();

    // Tree cache invalidation should not crash on empty
    tc.invalidate("some/path");
}
