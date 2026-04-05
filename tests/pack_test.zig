// Pack subsystem tests

const std = @import("std");
const pack = @import("../src/pack/mod.zig");
const object = @import("../src/object/mod.zig");

test "pack header parse" {
    var data: [32]u8 = undefined;
    @memcpy(data[0..4], "PACK");
    std.mem.writeInt(u32, data[4..8], 2, .big);
    std.mem.writeInt(u32, data[8..12], 0, .big);
    @memset(data[12..], 0);

    const p = try pack.Pack.parse(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(u32, 0), p.object_count);
}

test "pack invalid signature" {
    var data = [_]u8{ 'N', 'O', 'P', 'E' } ++ [_]u8{0} ** 28;
    try std.testing.expectError(error.InvalidSignature, pack.Pack.parse(std.testing.allocator, &data));
}

test "pack writer roundtrip" {
    const allocator = std.testing.allocator;

    var writer = pack.PackWriter.init(allocator);
    defer writer.deinit();

    const content = "test content for pack";
    const sha = object.hash.hash(content);
    try writer.addObject(.blob, content, sha);

    const pack_data = try writer.write();
    defer allocator.free(pack_data);

    // Verify header
    try std.testing.expectEqualStrings("PACK", pack_data[0..4]);
    const version = std.mem.readInt(u32, pack_data[4..8], .big);
    try std.testing.expectEqual(@as(u32, 2), version);
    const count = std.mem.readInt(u32, pack_data[8..12], .big);
    try std.testing.expectEqual(@as(u32, 1), count);
}

test "delta apply insert" {
    const allocator = std.testing.allocator;

    const base = "";
    var delta: [10]u8 = undefined;
    delta[0] = 0; // base size
    delta[1] = 5; // result size
    delta[2] = 5; // insert 5 bytes
    @memcpy(delta[3..8], "hello");

    const result = try pack.applyDelta(allocator, base, delta[0..8]);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello", result);
}

test "delta apply copy" {
    const allocator = std.testing.allocator;

    const base = "hello world";
    var delta: [10]u8 = undefined;
    delta[0] = 11; // base size
    delta[1] = 5; // result size
    delta[2] = 0x91; // copy with offset and size
    delta[3] = 0; // offset = 0
    delta[4] = 5; // size = 5

    const result = try pack.applyDelta(allocator, base, delta[0..5]);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello", result);
}

test "delta create and apply roundtrip" {
    const allocator = std.testing.allocator;

    const base = "The quick brown fox jumps over the lazy dog.";
    const target = "The quick brown cat jumps over the lazy dog.";

    const delta = try pack.createDelta(allocator, base, target);
    defer allocator.free(delta);

    const reconstructed = try pack.applyDelta(allocator, base, delta);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualStrings(target, reconstructed);
}

test "delta create identical" {
    const allocator = std.testing.allocator;

    const text = "identical content here";

    const delta = try pack.createDelta(allocator, text, text);
    defer allocator.free(delta);

    const reconstructed = try pack.applyDelta(allocator, text, delta);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualStrings(text, reconstructed);
}

test "pack index v2 header" {
    var data: [8 + 256 * 4 + 20]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0xff744f63, .big);
    std.mem.writeInt(u32, data[4..8], 2, .big);
    @memset(data[8 .. 8 + 256 * 4], 0);

    var idx = try pack.PackIndex.parse(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(u32, 0), idx.total_objects);
}

test "pack index writer" {
    const allocator = std.testing.allocator;

    var writer = pack.PackIndexWriter.init(allocator);
    defer writer.deinit();

    const sha1 = object.hash.hash("object 1");
    const sha2 = object.hash.hash("object 2");

    try writer.addEntry(sha1, 0x12345678, 12);
    try writer.addEntry(sha2, 0xABCDEF01, 256);

    const pack_sha = object.hash.hash("pack content");
    const index_data = try writer.write(pack_sha);
    defer allocator.free(index_data);

    const magic = std.mem.readInt(u32, index_data[0..4], .big);
    try std.testing.expectEqual(@as(u32, 0xff744f63), magic);
}
