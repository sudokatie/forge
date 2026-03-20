// Git pack file reading

const std = @import("std");
const hash_mod = @import("../object/hash.zig");

pub const ObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

pub const PackObject = struct {
    obj_type: ObjectType,
    data: []const u8,
    base_offset: ?u64, // For OFS_DELTA
    base_sha: ?hash_mod.Sha1, // For REF_DELTA
};

pub const Pack = struct {
    data: []const u8,
    object_count: u32,
    allocator: std.mem.Allocator,

    /// Open and parse a pack file
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Pack {
        const data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024 * 1024);
        errdefer allocator.free(data);

        return try parse(allocator, data);
    }

    /// Parse pack from memory
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Pack {
        if (data.len < 12) return error.PackTooShort;

        // Header: "PACK" + version + object count
        if (!std.mem.eql(u8, data[0..4], "PACK")) return error.InvalidSignature;

        const version = std.mem.readInt(u32, data[4..8], .big);
        if (version != 2 and version != 3) return error.UnsupportedVersion;

        const object_count = std.mem.readInt(u32, data[8..12], .big);

        return Pack{
            .data = data,
            .object_count = object_count,
            .allocator = allocator,
        };
    }

    /// Read object at given offset
    pub fn readObject(self: *Pack, offset: usize) !PackObject {
        if (offset >= self.data.len) return error.OffsetOutOfBounds;

        var pos = offset;

        // Read type and size (variable length encoding)
        const first_byte = self.data[pos];
        pos += 1;

        const obj_type: ObjectType = @enumFromInt((first_byte >> 4) & 0x7);
        var size: u64 = first_byte & 0x0F;
        var shift: u6 = 4;

        while (self.data[pos - 1] & 0x80 != 0) {
            if (pos >= self.data.len) return error.UnexpectedEnd;
            const byte = self.data[pos];
            pos += 1;
            size |= @as(u64, byte & 0x7F) << shift;
            shift += 7;
        }

        var base_offset: ?u64 = null;
        var base_sha: ?hash_mod.Sha1 = null;

        // Handle delta bases
        if (obj_type == .ofs_delta) {
            // Read negative offset
            var ofs: u64 = self.data[pos] & 0x7F;
            while (self.data[pos] & 0x80 != 0) {
                pos += 1;
                ofs = ((ofs + 1) << 7) | (self.data[pos] & 0x7F);
            }
            pos += 1;
            base_offset = offset - ofs;
        } else if (obj_type == .ref_delta) {
            if (pos + 20 > self.data.len) return error.UnexpectedEnd;
            base_sha = self.data[pos..][0..20].*;
            pos += 20;
        }

        // Decompress data (zlib)
        // For now, return the compressed data position
        // TODO: Actual decompression - size is uncompressed size
        const data_end = @min(pos + @as(usize, @intCast(size)) + 256, self.data.len);

        return PackObject{
            .obj_type = obj_type,
            .data = self.data[pos..data_end],
            .base_offset = base_offset,
            .base_sha = base_sha,
        };
    }

    pub fn deinit(self: *Pack) void {
        self.allocator.free(self.data);
    }
};

// Tests
test "pack header parse" {
    // Minimal valid pack header
    var data: [32]u8 = undefined;
    @memcpy(data[0..4], "PACK");
    std.mem.writeInt(u32, data[4..8], 2, .big); // version
    std.mem.writeInt(u32, data[8..12], 0, .big); // 0 objects
    @memset(data[12..], 0);

    // Don't use allocator since we're using stack data
    const pack = try Pack.parse(std.testing.allocator, &data);
    // Don't call deinit - data is on stack

    try std.testing.expectEqual(@as(u32, 0), pack.object_count);
}

test "pack invalid signature" {
    var data = [_]u8{ 'N', 'O', 'P', 'E' } ++ [_]u8{0} ** 28;
    const result = Pack.parse(std.testing.allocator, &data);
    try std.testing.expectError(error.InvalidSignature, result);
}
