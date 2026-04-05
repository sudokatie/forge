// Git pack file reading and writing

const std = @import("std");
const hash_mod = @import("../object/hash.zig");

// Use system zlib
const c = @cImport({
    @cInclude("zlib.h");
});

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

/// Decompress zlib data
fn decompressData(allocator: std.mem.Allocator, data: []const u8, expected_size: usize) ![]u8 {
    var dest_size: usize = if (expected_size > 0) expected_size else data.len * 4;
    if (dest_size < 1024) dest_size = 1024;

    while (true) {
        const decompressed = try allocator.alloc(u8, dest_size);
        errdefer allocator.free(decompressed);

        var dest_len: c_ulong = @intCast(dest_size);
        const result = c.uncompress(
            decompressed.ptr,
            &dest_len,
            data.ptr,
            @intCast(data.len),
        );

        if (result == c.Z_OK) {
            return allocator.realloc(decompressed, dest_len);
        } else if (result == c.Z_BUF_ERROR) {
            allocator.free(decompressed);
            dest_size *= 2;
            if (dest_size > 1024 * 1024 * 100) {
                return error.DecompressionBufferTooLarge;
            }
        } else {
            return error.DecompressionFailed;
        }
    }
}

/// Compress data with zlib
fn compressData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const bound = c.compressBound(@intCast(data.len));
    const compressed = try allocator.alloc(u8, bound);
    errdefer allocator.free(compressed);

    var dest_len: c_ulong = bound;
    const result = c.compress(
        compressed.ptr,
        &dest_len,
        data.ptr,
        @intCast(data.len),
    );

    if (result != c.Z_OK) {
        return error.CompressionFailed;
    }

    return allocator.realloc(compressed, dest_len);
}

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

    /// Read and decompress object at given offset
    pub fn readObject(self: *Pack, offset: usize) !struct {
        obj_type: ObjectType,
        data: []u8,
        base_offset: ?u64,
        base_sha: ?hash_mod.Sha1,
        consumed: usize,
    } {
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
            shift +|= 7;
        }

        var base_offset: ?u64 = null;
        var base_sha: ?hash_mod.Sha1 = null;

        // Handle delta bases
        if (obj_type == .ofs_delta) {
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

        // Find end of compressed data by decompressing
        // We need to try decompressing to find where it ends
        const compressed_start = pos;
        const remaining = self.data[compressed_start..];

        // Decompress the data
        const decompressed = try decompressData(self.allocator, remaining, @intCast(size));

        // Calculate how much compressed data was consumed
        // This is tricky - we'll estimate based on zlib stream
        var consumed: usize = 0;
        {
            var stream: c.z_stream = std.mem.zeroes(c.z_stream);
            stream.next_in = @constCast(remaining.ptr);
            stream.avail_in = @intCast(remaining.len);

            if (c.inflateInit(&stream) != c.Z_OK) {
                return error.ZlibInitFailed;
            }
            defer _ = c.inflateEnd(&stream);

            var out_buf: [65536]u8 = undefined;
            stream.next_out = &out_buf;
            stream.avail_out = out_buf.len;

            while (true) {
                const ret = c.inflate(&stream, c.Z_NO_FLUSH);
                if (ret == c.Z_STREAM_END) break;
                if (ret != c.Z_OK) break;
                if (stream.avail_out == 0) {
                    stream.next_out = &out_buf;
                    stream.avail_out = out_buf.len;
                }
            }

            consumed = remaining.len - stream.avail_in;
        }

        return .{
            .obj_type = obj_type,
            .data = decompressed,
            .base_offset = base_offset,
            .base_sha = base_sha,
            .consumed = pos - offset + consumed,
        };
    }

    pub const ResolvedObject = struct {
        obj_type: ObjectType,
        data: []u8,
    };

    /// Resolve a deltified object to its final form
    pub fn resolveObject(self: *Pack, offset: usize) !ResolvedObject {
        return self.resolveObjectWithIndex(offset, null);
    }

    /// Resolve a deltified object using an optional pack index for REF_DELTA
    pub fn resolveObjectWithIndex(
        self: *Pack,
        offset: usize,
        pack_index: ?*const @import("index.zig").PackIndex,
    ) !ResolvedObject {
        const delta_mod = @import("delta.zig");

        const obj = try self.readObject(offset);

        if (obj.obj_type == .ofs_delta) {
            // Resolve base recursively
            const base = try self.resolveObjectWithIndex(@intCast(obj.base_offset.?), pack_index);
            defer self.allocator.free(base.data);

            const resolved = try delta_mod.applyDelta(self.allocator, base.data, obj.data);
            self.allocator.free(obj.data);

            return .{ .obj_type = base.obj_type, .data = resolved };
        } else if (obj.obj_type == .ref_delta) {
            // Look up base by SHA using pack index
            if (pack_index) |idx| {
                const base_offset = idx.lookup(obj.base_sha.?) orelse return error.RefDeltaBaseNotFound;
                const base = try self.resolveObjectWithIndex(@intCast(base_offset), pack_index);
                defer self.allocator.free(base.data);

                const resolved = try delta_mod.applyDelta(self.allocator, base.data, obj.data);
                self.allocator.free(obj.data);

                return .{ .obj_type = base.obj_type, .data = resolved };
            } else {
                // No index provided - can't resolve REF_DELTA
                self.allocator.free(obj.data);
                return error.RefDeltaRequiresIndex;
            }
        }

        return .{ .obj_type = obj.obj_type, .data = obj.data };
    }

    /// Build an in-memory SHA -> offset map for this pack
    pub fn buildShaMap(self: *Pack) !std.AutoHashMap(hash_mod.Sha1, u64) {
        var map = std.AutoHashMap(hash_mod.Sha1, u64).init(self.allocator);
        errdefer map.deinit();

        var offset: usize = 12; // Skip header

        for (0..self.object_count) |_| {
            const start_offset = offset;
            const obj = self.readObject(offset) catch break;
            defer self.allocator.free(obj.data);

            // Compute SHA for non-delta objects
            if (obj.obj_type != .ofs_delta and obj.obj_type != .ref_delta) {
                const type_str = switch (obj.obj_type) {
                    .commit => "commit",
                    .tree => "tree",
                    .blob => "blob",
                    .tag => "tag",
                    else => continue,
                };

                var header_buf: [64]u8 = undefined;
                const header = std.fmt.bufPrint(&header_buf, "{s} {d}\x00", .{ type_str, obj.data.len }) catch continue;

                var hasher = std.crypto.hash.Sha1.init(.{});
                hasher.update(header);
                hasher.update(obj.data);
                const sha = hasher.finalResult();

                try map.put(sha, start_offset);
            }

            offset += obj.consumed;
        }

        return map;
    }

    pub fn deinit(self: *Pack) void {
        self.allocator.free(self.data);
    }
};

/// Write a pack file from a list of objects
pub const PackWriter = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(PackEntry),

    pub const PackEntry = struct {
        obj_type: ObjectType,
        data: []const u8,
        sha: hash_mod.Sha1,
    };

    pub fn init(allocator: std.mem.Allocator) PackWriter {
        return .{
            .allocator = allocator,
            .objects = .empty,
        };
    }

    pub fn addObject(self: *PackWriter, obj_type: ObjectType, data: []const u8, sha: hash_mod.Sha1) !void {
        try self.objects.append(self.allocator, .{
            .obj_type = obj_type,
            .data = data,
            .sha = sha,
        });
    }

    /// Generate pack file bytes
    pub fn write(self: *PackWriter) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        // Header
        try result.appendSlice(self.allocator, "PACK");
        var version: [4]u8 = undefined;
        std.mem.writeInt(u32, &version, 2, .big);
        try result.appendSlice(self.allocator, &version);
        var count: [4]u8 = undefined;
        std.mem.writeInt(u32, &count, @intCast(self.objects.items.len), .big);
        try result.appendSlice(self.allocator, &count);

        // Objects
        for (self.objects.items) |obj| {
            // Write type/size header
            try writeVarInt(&result, self.allocator, @intFromEnum(obj.obj_type), obj.data.len);

            // Write compressed data
            const compressed = try compressData(self.allocator, obj.data);
            defer self.allocator.free(compressed);
            try result.appendSlice(self.allocator, compressed);
        }

        // Checksum
        const sha = hash_mod.hash(result.items);
        try result.appendSlice(self.allocator, &sha);

        return try result.toOwnedSlice(self.allocator);
    }

    fn writeVarInt(result: *std.ArrayList(u8), allocator: std.mem.Allocator, obj_type: u3, size: usize) !void {
        // First byte: type in bits 4-6, low 4 bits of size
        var first: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(size & 0x0F));
        var remaining = size >> 4;

        if (remaining > 0) {
            first |= 0x80;
        }
        try result.append(allocator, first);

        while (remaining > 0) {
            var byte: u8 = @intCast(remaining & 0x7F);
            remaining >>= 7;
            if (remaining > 0) {
                byte |= 0x80;
            }
            try result.append(allocator, byte);
        }
    }

    pub fn deinit(self: *PackWriter) void {
        self.objects.deinit(self.allocator);
    }
};

// Tests
test "pack header parse" {
    var data: [32]u8 = undefined;
    @memcpy(data[0..4], "PACK");
    std.mem.writeInt(u32, data[4..8], 2, .big);
    std.mem.writeInt(u32, data[8..12], 0, .big);
    @memset(data[12..], 0);

    const pack = try Pack.parse(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(u32, 0), pack.object_count);
}

test "pack invalid signature" {
    var data = [_]u8{ 'N', 'O', 'P', 'E' } ++ [_]u8{0} ** 28;
    const result = Pack.parse(std.testing.allocator, &data);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "pack writer basic" {
    const allocator = std.testing.allocator;

    var writer = PackWriter.init(allocator);
    defer writer.deinit();

    const sha = hash_mod.hash("test content");
    try writer.addObject(.blob, "test content", sha);

    const pack_data = try writer.write();
    defer allocator.free(pack_data);

    // Verify header
    try std.testing.expectEqualStrings("PACK", pack_data[0..4]);
    const version = std.mem.readInt(u32, pack_data[4..8], .big);
    try std.testing.expectEqual(@as(u32, 2), version);
    const count = std.mem.readInt(u32, pack_data[8..12], .big);
    try std.testing.expectEqual(@as(u32, 1), count);
}
