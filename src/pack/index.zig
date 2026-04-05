// Git pack index file reading and writing (version 2)

const std = @import("std");
const hash_mod = @import("../object/hash.zig");

pub const PackIndex = struct {
    data: []const u8,
    fanout: [256]u32,
    total_objects: u32,
    allocator: std.mem.Allocator,

    /// Open and parse a pack index file
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !PackIndex {
        const data = try std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024);
        errdefer allocator.free(data);

        return try parse(allocator, data);
    }

    /// Parse pack index from memory
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !PackIndex {
        // Version 2 header: 0xff744f63 + version 2
        if (data.len < 8) return error.IndexTooShort;

        const magic = std.mem.readInt(u32, data[0..4], .big);
        if (magic == 0xff744f63) {
            // Version 2 format
            const version = std.mem.readInt(u32, data[4..8], .big);
            if (version != 2) return error.UnsupportedVersion;

            return try parseV2(allocator, data);
        } else {
            // Version 1 format (fanout starts at byte 0)
            return try parseV1(allocator, data);
        }
    }

    fn parseV2(allocator: std.mem.Allocator, data: []const u8) !PackIndex {
        if (data.len < 8 + 256 * 4) return error.IndexTooShort;

        // Read fanout table (256 entries, 4 bytes each)
        var fanout: [256]u32 = undefined;
        var pos: usize = 8;
        for (0..256) |i| {
            fanout[i] = std.mem.readInt(u32, data[pos..][0..4], .big);
            pos += 4;
        }

        const total = fanout[255];

        return PackIndex{
            .data = data,
            .fanout = fanout,
            .total_objects = total,
            .allocator = allocator,
        };
    }

    fn parseV1(allocator: std.mem.Allocator, data: []const u8) !PackIndex {
        if (data.len < 256 * 4) return error.IndexTooShort;

        var fanout: [256]u32 = undefined;
        for (0..256) |i| {
            fanout[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .big);
        }

        const total = fanout[255];

        return PackIndex{
            .data = data,
            .fanout = fanout,
            .total_objects = total,
            .allocator = allocator,
        };
    }

    /// Look up an object by SHA and return its pack offset
    pub fn lookup(self: *const PackIndex, sha: hash_mod.Sha1) ?u64 {
        const first_byte = sha[0];

        // Get range from fanout
        const start: u32 = if (first_byte == 0) 0 else self.fanout[first_byte - 1];
        const end: u32 = self.fanout[first_byte];

        if (start >= end) return null;

        // Binary search in SHA table
        const sha_table_offset: usize = 8 + 256 * 4; // After header + fanout
        const offset_table_offset = sha_table_offset + @as(usize, self.total_objects) * 20 + @as(usize, self.total_objects) * 4;

        var lo: u32 = start;
        var hi: u32 = end;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry_pos = sha_table_offset + @as(usize, mid) * 20;

            if (entry_pos + 20 > self.data.len) return null;

            const entry_sha = self.data[entry_pos..][0..20];

            const cmp = std.mem.order(u8, entry_sha, &sha);
            if (cmp == .eq) {
                // Found! Get offset from offset table
                const offset_pos = offset_table_offset + @as(usize, mid) * 4;
                if (offset_pos + 4 > self.data.len) return null;
                return std.mem.readInt(u32, self.data[offset_pos..][0..4], .big);
            } else if (cmp == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        return null;
    }

    /// Get SHA at index position
    pub fn getSha(self: *const PackIndex, index: u32) ?hash_mod.Sha1 {
        if (index >= self.total_objects) return null;

        const sha_table_offset: usize = 8 + 256 * 4;
        const pos = sha_table_offset + @as(usize, index) * 20;

        if (pos + 20 > self.data.len) return null;
        return self.data[pos..][0..20].*;
    }

    pub fn deinit(self: *PackIndex) void {
        self.allocator.free(self.data);
    }
};

/// Write a pack index file (version 2)
pub const PackIndexWriter = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(IndexEntry),

    pub const IndexEntry = struct {
        sha: hash_mod.Sha1,
        crc: u32,
        offset: u64,
    };

    pub fn init(allocator: std.mem.Allocator) PackIndexWriter {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn addEntry(self: *PackIndexWriter, sha: hash_mod.Sha1, crc: u32, offset: u64) !void {
        try self.entries.append(self.allocator, .{
            .sha = sha,
            .crc = crc,
            .offset = offset,
        });
    }

    /// Generate index file bytes
    pub fn write(self: *PackIndexWriter, pack_sha: hash_mod.Sha1) ![]u8 {
        // Sort entries by SHA
        std.mem.sort(IndexEntry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: IndexEntry, b: IndexEntry) bool {
                return std.mem.order(u8, &a.sha, &b.sha) == .lt;
            }
        }.lessThan);

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        // Magic + version
        var magic: [4]u8 = undefined;
        std.mem.writeInt(u32, &magic, 0xff744f63, .big);
        try result.appendSlice(self.allocator, &magic);

        var version: [4]u8 = undefined;
        std.mem.writeInt(u32, &version, 2, .big);
        try result.appendSlice(self.allocator, &version);

        // Fanout table
        var fanout: [256]u32 = undefined;
        var count: u32 = 0;
        for (0..256) |i| {
            for (self.entries.items) |entry| {
                if (entry.sha[0] == i) {
                    count += 1;
                }
            }
            fanout[i] = count;
        }

        // Actually we need cumulative counts
        count = 0;
        for (0..256) |i| {
            for (self.entries.items) |entry| {
                if (entry.sha[0] == i) {
                    count += 1;
                }
            }
            fanout[i] = count;
        }

        for (fanout) |f| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, f, .big);
            try result.appendSlice(self.allocator, &buf);
        }

        // SHA-1 list
        for (self.entries.items) |entry| {
            try result.appendSlice(self.allocator, &entry.sha);
        }

        // CRC32 list
        for (self.entries.items) |entry| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, entry.crc, .big);
            try result.appendSlice(self.allocator, &buf);
        }

        // Offset list (4-byte, with MSB flag for large offsets)
        var large_offsets: std.ArrayList(u64) = .empty;
        defer large_offsets.deinit(self.allocator);

        for (self.entries.items) |entry| {
            var buf: [4]u8 = undefined;
            if (entry.offset >= 0x80000000) {
                // Large offset - store index into large offset table with MSB set
                std.mem.writeInt(u32, &buf, @as(u32, @intCast(large_offsets.items.len)) | 0x80000000, .big);
                try large_offsets.append(self.allocator, entry.offset);
            } else {
                std.mem.writeInt(u32, &buf, @intCast(entry.offset), .big);
            }
            try result.appendSlice(self.allocator, &buf);
        }

        // Large offset list (8-byte entries)
        for (large_offsets.items) |offset| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, offset, .big);
            try result.appendSlice(self.allocator, &buf);
        }

        // Pack SHA-1
        try result.appendSlice(self.allocator, &pack_sha);

        // Index SHA-1
        const index_sha = hash_mod.hash(result.items);
        try result.appendSlice(self.allocator, &index_sha);

        return try result.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *PackIndexWriter) void {
        self.entries.deinit(self.allocator);
    }
};

// Tests
test "pack index v2 header" {
    var data: [8 + 256 * 4 + 20]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0xff744f63, .big);
    std.mem.writeInt(u32, data[4..8], 2, .big);
    @memset(data[8 .. 8 + 256 * 4], 0);

    const idx = try PackIndex.parse(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(u32, 0), idx.total_objects);
}

test "pack index lookup not found" {
    var data: [8 + 256 * 4 + 20]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0xff744f63, .big);
    std.mem.writeInt(u32, data[4..8], 2, .big);
    @memset(data[8..], 0);

    var idx = try PackIndex.parse(std.testing.allocator, &data);
    const fake_sha = hash_mod.hash("nonexistent");
    try std.testing.expect(idx.lookup(fake_sha) == null);
}

test "pack index writer" {
    const allocator = std.testing.allocator;

    var writer = PackIndexWriter.init(allocator);
    defer writer.deinit();

    const sha1 = hash_mod.hash("object 1");
    const sha2 = hash_mod.hash("object 2");

    try writer.addEntry(sha1, 0x12345678, 12);
    try writer.addEntry(sha2, 0xABCDEF01, 256);

    const pack_sha = hash_mod.hash("pack content");
    const index_data = try writer.write(pack_sha);
    defer allocator.free(index_data);

    // Verify header
    const magic = std.mem.readInt(u32, index_data[0..4], .big);
    try std.testing.expectEqual(@as(u32, 0xff744f63), magic);
}
