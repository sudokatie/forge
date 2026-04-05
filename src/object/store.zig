// Object store - .git/objects database

const std = @import("std");
const hash_mod = @import("hash.zig");
const blob = @import("blob.zig");
const tree = @import("tree.zig");
const commit = @import("commit.zig");
const tag = @import("tag.zig");

// Use system zlib for Git-compatible compression
const c = @cImport({
    @cInclude("zlib.h");
});

/// Compress data using zlib (Git-compatible)
fn compressData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Calculate upper bound for compressed size
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

    // Shrink to actual size
    return allocator.realloc(compressed, dest_len);
}

/// Decompress zlib data (Git-compatible)
fn decompressData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Start with a reasonable buffer, grow if needed
    var dest_size: usize = data.len * 4;
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
            // Shrink to actual size
            return allocator.realloc(decompressed, dest_len);
        } else if (result == c.Z_BUF_ERROR) {
            // Buffer too small, grow and retry
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

pub const ObjectType = enum {
    blob,
    tree,
    commit,
    tag,
};

pub const Object = union(ObjectType) {
    blob: blob.Blob,
    tree: tree.Tree,
    commit: commit.Commit,
    tag: tag.Tag,
};

pub const ObjectStore = struct {
    git_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) ObjectStore {
        return .{
            .git_dir = git_dir,
            .allocator = allocator,
        };
    }

    /// Check if object exists
    pub fn exists(self: *ObjectStore, oid: hash_mod.Sha1) bool {
        const hex = hash_mod.toHex(oid);
        const path = std.fmt.allocPrint(self.allocator, "{s}/objects/{s}/{s}", .{
            self.git_dir,
            hex[0..2],
            hex[2..],
        }) catch return false;
        defer self.allocator.free(path);

        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// Write object and return its SHA-1
    pub fn write(self: *ObjectStore, obj_type: ObjectType, content: []const u8) !hash_mod.Sha1 {
        // Compute hash of header + content
        const type_str = switch (obj_type) {
            .blob => "blob",
            .tree => "tree",
            .commit => "commit",
            .tag => "tag",
        };

        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "{s} {d}\x00", .{ type_str, content.len }) catch unreachable;

        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(header);
        hasher.update(content);
        const oid = hasher.finalResult();

        // Check if already exists
        if (self.exists(oid)) {
            return oid;
        }

        // Write compressed object
        const hex = hash_mod.toHex(oid);
        const dir_path = try std.fmt.allocPrint(self.allocator, "{s}/objects/{s}", .{
            self.git_dir,
            hex[0..2],
        });
        defer self.allocator.free(dir_path);

        std.fs.cwd().makeDir(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/objects/{s}/{s}", .{
            self.git_dir,
            hex[0..2],
            hex[2..],
        });
        defer self.allocator.free(file_path);

        // Prepare data to compress
        var data_to_compress: std.ArrayList(u8) = .empty;
        defer data_to_compress.deinit(self.allocator);
        try data_to_compress.appendSlice(self.allocator, header);
        try data_to_compress.appendSlice(self.allocator, content);

        // Compress with zlib
        const compressed = try compressData(self.allocator, data_to_compress.items);
        defer self.allocator.free(compressed);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(compressed);

        return oid;
    }

    /// Read raw object data by SHA-1 (returns type string and content)
    pub fn readRaw(self: *ObjectStore, oid: hash_mod.Sha1) !struct { type_str: []const u8, content: []const u8, data: []u8 } {
        const hex = hash_mod.toHex(oid);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/objects/{s}/{s}", .{
            self.git_dir,
            hex[0..2],
            hex[2..],
        });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const compressed = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 100);
        defer self.allocator.free(compressed);

        // Decompress with zlib
        const decompressed = try decompressData(self.allocator, compressed);

        // Parse header
        const null_pos = std.mem.indexOf(u8, decompressed, "\x00") orelse {
            self.allocator.free(decompressed);
            return error.InvalidObject;
        };
        const header = decompressed[0..null_pos];
        const content = decompressed[null_pos + 1 ..];

        // Find type
        const space_pos = std.mem.indexOf(u8, header, " ") orelse {
            self.allocator.free(decompressed);
            return error.InvalidObject;
        };
        const type_str = header[0..space_pos];

        return .{ .type_str = type_str, .content = content, .data = decompressed };
    }

    /// Read object by SHA-1
    pub fn read(self: *ObjectStore, oid: hash_mod.Sha1) !Object {
        const raw = try self.readRaw(oid);
        defer self.allocator.free(raw.data);

        // Determine type and parse
        if (std.mem.eql(u8, raw.type_str, "blob")) {
            return Object{ .blob = blob.parse(raw.content) };
        } else if (std.mem.eql(u8, raw.type_str, "tree")) {
            return Object{ .tree = try tree.parse(self.allocator, raw.content) };
        } else if (std.mem.eql(u8, raw.type_str, "commit")) {
            return Object{ .commit = try commit.parse(self.allocator, raw.content) };
        } else if (std.mem.eql(u8, raw.type_str, "tag")) {
            return Object{ .tag = try tag.parse(self.allocator, raw.content) };
        }

        return error.UnknownObjectType;
    }

    /// Get object type and size without fully parsing
    pub fn statObject(self: *ObjectStore, oid: hash_mod.Sha1) !struct { obj_type: ObjectType, size: usize } {
        const raw = try self.readRaw(oid);
        defer self.allocator.free(raw.data);

        const obj_type: ObjectType = if (std.mem.eql(u8, raw.type_str, "blob"))
            .blob
        else if (std.mem.eql(u8, raw.type_str, "tree"))
            .tree
        else if (std.mem.eql(u8, raw.type_str, "commit"))
            .commit
        else if (std.mem.eql(u8, raw.type_str, "tag"))
            .tag
        else
            return error.UnknownObjectType;

        return .{ .obj_type = obj_type, .size = raw.content.len };
    }
};

test "zlib compression roundtrip" {
    const allocator = std.testing.allocator;

    const data = "Hello, Git! This is a test of zlib compression.";
    const compressed = try compressData(allocator, data);
    defer allocator.free(compressed);

    // Compressed should be different
    try std.testing.expect(!std.mem.eql(u8, data, compressed));

    const decompressed = try decompressData(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(data, decompressed);
}

test "compress empty data" {
    const allocator = std.testing.allocator;

    const compressed = try compressData(allocator, "");
    defer allocator.free(compressed);

    const decompressed = try decompressData(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings("", decompressed);
}

test "compress large data" {
    const allocator = std.testing.allocator;

    // Create large repetitive data (compresses well)
    const data = "ABCDEFGHIJ" ** 1000;
    const compressed = try compressData(allocator, data);
    defer allocator.free(compressed);

    // Should be significantly smaller
    try std.testing.expect(compressed.len < data.len);

    const decompressed = try decompressData(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(data, decompressed);
}
