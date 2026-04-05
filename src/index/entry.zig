// Git index entry - represents a staged file

const std = @import("std");
const hash_mod = @import("../object/hash.zig");

/// Index entry - represents a staged file
pub const IndexEntry = struct {
    /// Stat data
    ctime_s: u32,
    ctime_ns: u32,
    mtime_s: u32,
    mtime_ns: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u32,

    /// Object SHA-1
    sha: hash_mod.Sha1,

    /// Flags (includes name length in lower 12 bits)
    flags: u16,

    /// Extended flags (for version 3+)
    extended_flags: u16 = 0,

    /// File path (relative to repo root)
    path: []const u8,

    /// Stage number (0 = normal, 1-3 = merge conflict)
    pub fn stage(self: IndexEntry) u2 {
        return @intCast((self.flags >> 12) & 0x3);
    }

    /// Check if entry has extended flag set
    pub fn hasExtended(self: IndexEntry) bool {
        return (self.flags & 0x4000) != 0;
    }

    /// Check if entry is assumed unchanged
    pub fn isAssumeValid(self: IndexEntry) bool {
        return (self.flags & 0x8000) != 0;
    }

    /// Check if intent-to-add
    pub fn isIntentToAdd(self: IndexEntry) bool {
        return (self.extended_flags & 0x2000) != 0;
    }

    /// Check if skip-worktree
    pub fn isSkipWorktree(self: IndexEntry) bool {
        return (self.extended_flags & 0x4000) != 0;
    }

    /// Parse entry from binary data, returns entry and bytes consumed
    pub fn parse(allocator: std.mem.Allocator, data: []const u8, version: u32) !struct { entry: IndexEntry, size: usize } {
        if (data.len < 62) return error.EntryTooShort;

        var entry = IndexEntry{
            .ctime_s = std.mem.readInt(u32, data[0..4], .big),
            .ctime_ns = std.mem.readInt(u32, data[4..8], .big),
            .mtime_s = std.mem.readInt(u32, data[8..12], .big),
            .mtime_ns = std.mem.readInt(u32, data[12..16], .big),
            .dev = std.mem.readInt(u32, data[16..20], .big),
            .ino = std.mem.readInt(u32, data[20..24], .big),
            .mode = std.mem.readInt(u32, data[24..28], .big),
            .uid = std.mem.readInt(u32, data[28..32], .big),
            .gid = std.mem.readInt(u32, data[32..36], .big),
            .size = std.mem.readInt(u32, data[36..40], .big),
            .sha = data[40..60].*,
            .flags = std.mem.readInt(u16, data[60..62], .big),
            .extended_flags = 0,
            .path = undefined,
        };

        var header_size: usize = 62;

        // Version 3+ has extended flags if the extended bit is set
        if (version >= 3 and entry.hasExtended()) {
            if (data.len < 64) return error.EntryTooShort;
            entry.extended_flags = std.mem.readInt(u16, data[62..64], .big);
            header_size = 64;
        }

        // Name length is in lower 12 bits of flags (0xFFF = max stored length)
        const name_len = entry.flags & 0xFFF;

        // If name_len == 0xFFF, the actual length is longer - find null terminator
        const path_start = header_size;
        var path_end: usize = undefined;

        if (name_len == 0xFFF) {
            // Long path - find null terminator
            path_end = std.mem.indexOf(u8, data[path_start..], "\x00") orelse return error.MissingNullTerminator;
        } else {
            path_end = name_len;
        }

        if (data.len < path_start + path_end) return error.EntryTooShort;
        entry.path = try allocator.dupe(u8, data[path_start .. path_start + path_end]);

        // Entry is padded to 8-byte boundary
        const entry_len = path_start + path_end + 1; // +1 for null terminator
        const padded_len = (entry_len + 7) & ~@as(usize, 7);

        return .{ .entry = entry, .size = padded_len };
    }

    /// Serialize entry to binary format
    pub fn serialize(self: IndexEntry, allocator: std.mem.Allocator, version: u32) ![]u8 {
        const path_len = self.path.len;
        const has_extended = version >= 3 and (self.extended_flags != 0 or self.hasExtended());
        const header_size: usize = if (has_extended) 64 else 62;
        const entry_len = header_size + path_len + 1;
        const padded_len = (entry_len + 7) & ~@as(usize, 7);

        const buf = try allocator.alloc(u8, padded_len);
        @memset(buf, 0);

        std.mem.writeInt(u32, buf[0..4], self.ctime_s, .big);
        std.mem.writeInt(u32, buf[4..8], self.ctime_ns, .big);
        std.mem.writeInt(u32, buf[8..12], self.mtime_s, .big);
        std.mem.writeInt(u32, buf[12..16], self.mtime_ns, .big);
        std.mem.writeInt(u32, buf[16..20], self.dev, .big);
        std.mem.writeInt(u32, buf[20..24], self.ino, .big);
        std.mem.writeInt(u32, buf[24..28], self.mode, .big);
        std.mem.writeInt(u32, buf[28..32], self.uid, .big);
        std.mem.writeInt(u32, buf[32..36], self.gid, .big);
        std.mem.writeInt(u32, buf[36..40], self.size, .big);
        @memcpy(buf[40..60], &self.sha);

        // Flags: name length in lower 12 bits, extended bit if needed
        var flags = self.flags & 0xF000; // Preserve upper bits
        flags |= @as(u16, @intCast(@min(path_len, 0xFFF)));
        if (has_extended) {
            flags |= 0x4000; // Extended flag
        }
        std.mem.writeInt(u16, buf[60..62], flags, .big);

        if (has_extended) {
            std.mem.writeInt(u16, buf[62..64], self.extended_flags, .big);
        }

        @memcpy(buf[header_size .. header_size + path_len], self.path);

        return buf;
    }

    /// Create entry from file stat
    pub fn fromStat(
        allocator: std.mem.Allocator,
        path: []const u8,
        sha: hash_mod.Sha1,
        stat: std.fs.File.Stat,
        mode: u32,
    ) !IndexEntry {
        return IndexEntry{
            .ctime_s = @intCast(@divTrunc(stat.ctime, std.time.ns_per_s)),
            .ctime_ns = @intCast(@mod(stat.ctime, std.time.ns_per_s)),
            .mtime_s = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s)),
            .mtime_ns = @intCast(@mod(stat.mtime, std.time.ns_per_s)),
            .dev = 0,
            .ino = 0,
            .mode = mode,
            .uid = 0,
            .gid = 0,
            .size = @intCast(stat.size),
            .sha = sha,
            .flags = 0,
            .extended_flags = 0,
            .path = try allocator.dupe(u8, path),
        };
    }
};

// Tests
test "entry parse v2" {
    const allocator = std.testing.allocator;

    // Minimal entry: 62 bytes header + "test.txt" + null + padding
    var data: [80]u8 = undefined;
    @memset(&data, 0);

    // Set path length in flags (8 bytes for "test.txt")
    std.mem.writeInt(u16, data[60..62], 8, .big);
    @memcpy(data[62..70], "test.txt");

    const result = try IndexEntry.parse(allocator, &data, 2);
    defer allocator.free(result.entry.path);

    try std.testing.expectEqualStrings("test.txt", result.entry.path);
    try std.testing.expectEqual(@as(usize, 72), result.size); // Padded to 8 bytes
}

test "entry serialize roundtrip" {
    const allocator = std.testing.allocator;

    const sha = hash_mod.hash("test content");
    const original = IndexEntry{
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
        .extended_flags = 0,
        .path = "test.txt",
    };

    const serialized = try original.serialize(allocator, 2);
    defer allocator.free(serialized);

    const parsed = try IndexEntry.parse(allocator, serialized, 2);
    defer allocator.free(parsed.entry.path);

    try std.testing.expectEqual(original.ctime_s, parsed.entry.ctime_s);
    try std.testing.expectEqual(original.mtime_s, parsed.entry.mtime_s);
    try std.testing.expectEqual(original.mode, parsed.entry.mode);
    try std.testing.expectEqual(original.size, parsed.entry.size);
    try std.testing.expectEqualStrings(original.path, parsed.entry.path);
}

test "entry stage extraction" {
    const entry = IndexEntry{
        .ctime_s = 0,
        .ctime_ns = 0,
        .mtime_s = 0,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .sha = undefined,
        .flags = 0x2000, // Stage 2
        .path = "",
    };

    try std.testing.expectEqual(@as(u2, 2), entry.stage());
}
