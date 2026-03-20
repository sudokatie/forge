// SHA-1 hashing for Git objects

const std = @import("std");

pub const Sha1 = [20]u8;
pub const Sha1Hex = [40]u8;

/// Compute SHA-1 hash of data
pub fn hash(data: []const u8) Sha1 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(data);
    return h.finalResult();
}

/// Compute SHA-1 hash of file contents
pub fn hashFile(allocator: std.mem.Allocator, path: []const u8) !Sha1 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 100); // 100MB max
    defer allocator.free(content);

    return hash(content);
}

/// Convert binary SHA-1 to hex string
pub fn toHex(sha: Sha1) Sha1Hex {
    var result: Sha1Hex = undefined;
    const hex_chars = "0123456789abcdef";

    for (sha, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    return result;
}

/// Convert hex string to binary SHA-1
pub fn fromHex(hex: []const u8) !Sha1 {
    if (hex.len != 40) return error.InvalidHexLength;

    var result: Sha1 = undefined;

    for (0..20) |i| {
        const high = try hexDigit(hex[i * 2]);
        const low = try hexDigit(hex[i * 2 + 1]);
        result[i] = (high << 4) | low;
    }

    return result;
}

fn hexDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => return error.InvalidHexChar,
    };
}

// Tests
test "hash empty string" {
    const result = hash("");
    const hex = toHex(result);
    try std.testing.expectEqualStrings("da39a3ee5e6b4b0d3255bfef95601890afd80709", &hex);
}

test "hash hello" {
    const result = hash("hello\n");
    const hex = toHex(result);
    try std.testing.expectEqualStrings("f572d396fae9206628714fb2ce00f72e94f2258f", &hex);
}

test "hex roundtrip" {
    const original = hash("test data");
    const hex = toHex(original);
    const recovered = try fromHex(&hex);
    try std.testing.expectEqual(original, recovered);
}

test "invalid hex length" {
    const result = fromHex("abc");
    try std.testing.expectError(error.InvalidHexLength, result);
}

test "invalid hex char" {
    const result = fromHex("gg39a3ee5e6b4b0d3255bfef95601890afd80709");
    try std.testing.expectError(error.InvalidHexChar, result);
}
