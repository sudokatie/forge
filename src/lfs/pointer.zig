const std = @import("std");
const Allocator = std.mem.Allocator;

/// Git LFS pointer file version
pub const LFS_VERSION = "https://git-lfs.github.com/spec/v1";

/// Maximum size for LFS pointer files (1KB should be plenty)
pub const MAX_POINTER_SIZE = 1024;

/// LFS pointer representing a large file stored in LFS
pub const Pointer = struct {
    /// SHA-256 hash of the actual content (64 hex chars)
    oid: [64]u8,
    /// Size of the actual content in bytes
    size: u64,

    const Self = @This();

    /// Parse a pointer from its file content
    pub fn parse(content: []const u8) !Self {
        var lines = std.mem.splitScalar(u8, content, '\n');

        // Line 1: version
        const version_line = lines.next() orelse return error.InvalidPointer;
        if (!std.mem.startsWith(u8, version_line, "version ")) {
            return error.InvalidPointer;
        }
        const version = version_line["version ".len..];
        if (!std.mem.eql(u8, version, LFS_VERSION)) {
            return error.UnsupportedLfsVersion;
        }

        // Line 2: oid sha256:<hash>
        const oid_line = lines.next() orelse return error.InvalidPointer;
        if (!std.mem.startsWith(u8, oid_line, "oid sha256:")) {
            return error.InvalidPointer;
        }
        const oid_hex = oid_line["oid sha256:".len..];
        if (oid_hex.len != 64) {
            return error.InvalidPointer;
        }

        // Line 3: size <decimal>
        const size_line = lines.next() orelse return error.InvalidPointer;
        if (!std.mem.startsWith(u8, size_line, "size ")) {
            return error.InvalidPointer;
        }
        const size_str = size_line["size ".len..];
        const size = std.fmt.parseInt(u64, size_str, 10) catch return error.InvalidPointer;

        var oid: [64]u8 = undefined;
        @memcpy(&oid, oid_hex);

        return Self{
            .oid = oid,
            .size = size,
        };
    }

    /// Format the pointer as file content
    pub fn format(self: Self, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "version {s}\noid sha256:{s}\nsize {d}\n", .{
            LFS_VERSION,
            &self.oid,
            self.size,
        });
    }

    /// Create a pointer from content by computing SHA-256
    pub fn fromContent(content: []const u8) Self {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(content);
        const digest = hasher.finalResult();

        var oid: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (digest, 0..) |byte, i| {
            oid[i * 2] = hex_chars[byte >> 4];
            oid[i * 2 + 1] = hex_chars[byte & 0x0f];
        }

        return Self{
            .oid = oid,
            .size = content.len,
        };
    }

    /// Check if content looks like an LFS pointer
    pub fn isPointer(content: []const u8) bool {
        if (content.len > MAX_POINTER_SIZE) return false;
        return std.mem.startsWith(u8, content, "version https://git-lfs.github.com/spec/v1\n");
    }

    /// Get the OID as a hex string slice
    pub fn oidHex(self: *const Self) []const u8 {
        return &self.oid;
    }
};

// Tests
test "parse valid pointer" {
    const content =
        \\version https://git-lfs.github.com/spec/v1
        \\oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        \\size 12345
        \\
    ;

    const ptr = try Pointer.parse(content);
    try std.testing.expectEqualStrings("4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393", &ptr.oid);
    try std.testing.expectEqual(@as(u64, 12345), ptr.size);
}

test "parse invalid pointer - wrong version" {
    const content =
        \\version https://example.com/invalid
        \\oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        \\size 12345
        \\
    ;

    try std.testing.expectError(error.UnsupportedLfsVersion, Pointer.parse(content));
}

test "parse invalid pointer - missing oid" {
    const content =
        \\version https://git-lfs.github.com/spec/v1
        \\size 12345
        \\
    ;

    try std.testing.expectError(error.InvalidPointer, Pointer.parse(content));
}

test "format pointer" {
    const ptr = Pointer{
        .oid = "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393".*,
        .size = 12345,
    };

    const allocator = std.testing.allocator;
    const formatted = try ptr.format(allocator);
    defer allocator.free(formatted);

    const expected =
        \\version https://git-lfs.github.com/spec/v1
        \\oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        \\size 12345
        \\
    ;
    try std.testing.expectEqualStrings(expected, formatted);
}

test "fromContent creates correct pointer" {
    const content = "Hello, LFS!";
    const ptr = Pointer.fromContent(content);

    try std.testing.expectEqual(@as(u64, 11), ptr.size);
    // SHA-256 of "Hello, LFS!"
    try std.testing.expectEqualStrings("969ada5a96b2d122a71a1d8da0f7cdf99ef19d46d5613e7be4ac07dbb6724bfa", &ptr.oid);
}

test "isPointer detects LFS pointers" {
    const valid =
        \\version https://git-lfs.github.com/spec/v1
        \\oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        \\size 12345
        \\
    ;
    try std.testing.expect(Pointer.isPointer(valid));

    const invalid = "This is just regular file content";
    try std.testing.expect(!Pointer.isPointer(invalid));

    // Large content should not be a pointer
    const large = "x" ** 2000;
    try std.testing.expect(!Pointer.isPointer(large));
}

test "roundtrip parse and format" {
    const allocator = std.testing.allocator;
    const original = Pointer{
        .oid = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890".*,
        .size = 999999,
    };

    const formatted = try original.format(allocator);
    defer allocator.free(formatted);

    const parsed = try Pointer.parse(formatted);
    try std.testing.expectEqualStrings(&original.oid, &parsed.oid);
    try std.testing.expectEqual(original.size, parsed.size);
}
