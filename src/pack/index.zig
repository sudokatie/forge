// Git pack index file reading (version 2)

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
    pub fn lookup(self: *PackIndex, sha: hash_mod.Sha1) ?u64 {
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
    pub fn getSha(self: *PackIndex, index: u32) ?hash_mod.Sha1 {
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

// Tests
test "pack index v2 header" {
    // Build minimal v2 index
    var data: [8 + 256 * 4 + 20]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0xff744f63, .big); // magic
    std.mem.writeInt(u32, data[4..8], 2, .big); // version

    // Fanout table (all zeros = 0 objects)
    @memset(data[8 .. 8 + 256 * 4], 0);

    const idx = try PackIndex.parse(std.testing.allocator, &data);
    // Don't deinit - stack data

    try std.testing.expectEqual(@as(u32, 0), idx.total_objects);
}

test "pack index lookup not found" {
    var data: [8 + 256 * 4 + 20]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0xff744f63, .big);
    std.mem.writeInt(u32, data[4..8], 2, .big);
    @memset(data[8..], 0);

    var idx = try PackIndex.parse(std.testing.allocator, &data);
    // Don't deinit - stack data

    const fake_sha = hash_mod.hash("nonexistent");
    try std.testing.expect(idx.lookup(fake_sha) == null);
}
