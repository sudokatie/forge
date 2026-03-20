// Blob objects - file contents

const std = @import("std");
const hash_mod = @import("hash.zig");

pub const Blob = struct {
    content: []const u8,

    pub fn init(content: []const u8) Blob {
        return .{ .content = content };
    }

    /// Compute the Git object hash for this blob
    pub fn computeHash(self: Blob) hash_mod.Sha1 {
        // Git blob format: "blob <size>\0<content>"
        var header_buf: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "blob {d}\x00", .{self.content.len}) catch unreachable;

        var h = std.crypto.hash.Sha1.init(.{});
        h.update(header);
        h.update(self.content);
        return h.finalResult();
    }
};

/// Parse blob from raw object data (after header)
pub fn parse(data: []const u8) Blob {
    return Blob.init(data);
}

/// Serialize blob for storage
pub fn serialize(allocator: std.mem.Allocator, blob: Blob) ![]u8 {
    const header = try std.fmt.allocPrint(allocator, "blob {d}\x00", .{blob.content.len});
    defer allocator.free(header);

    const result = try allocator.alloc(u8, header.len + blob.content.len);
    @memcpy(result[0..header.len], header);
    @memcpy(result[header.len..], blob.content);

    return result;
}

test "blob hash" {
    const blob = Blob.init("hello\n");
    const h = blob.computeHash();
    const hex = hash_mod.toHex(h);
    // This should match: echo "hello" | git hash-object --stdin
    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", &hex);
}

test "parse and serialize roundtrip" {
    const allocator = std.testing.allocator;
    const original = Blob.init("test content");

    const serialized = try serialize(allocator, original);
    defer allocator.free(serialized);

    // Find the null byte to skip header
    const null_pos = std.mem.indexOf(u8, serialized, "\x00").?;
    const parsed = parse(serialized[null_pos + 1 ..]);

    try std.testing.expectEqualStrings(original.content, parsed.content);
}
