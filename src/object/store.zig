// Object store - .git/objects database

const std = @import("std");
const hash_mod = @import("hash.zig");
const blob = @import("blob.zig");
const tree = @import("tree.zig");
const commit = @import("commit.zig");

// TODO: Implement proper zlib compression using std.compress.flate
// For now, store objects without compression for testing purposes.
// This is NOT Git-compatible but allows development/testing to proceed.
//
// The flate API in Zig 0.15 uses the new Io.Writer interface which requires
// more setup than the deprecated io.Writer. Proper implementation needed.

const UNCOMPRESSED_MARKER = "FORGE_UNCOMPRESSED:";

/// "Compress" data - currently stores uncompressed with marker
fn compressData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, UNCOMPRESSED_MARKER.len + data.len);
    @memcpy(result[0..UNCOMPRESSED_MARKER.len], UNCOMPRESSED_MARKER);
    @memcpy(result[UNCOMPRESSED_MARKER.len..], data);
    return result;
}

/// "Decompress" data - handles our marker or real zlib
fn decompressData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Check for our uncompressed marker
    if (std.mem.startsWith(u8, data, UNCOMPRESSED_MARKER)) {
        const content = data[UNCOMPRESSED_MARKER.len..];
        const result = try allocator.alloc(u8, content.len);
        @memcpy(result, content);
        return result;
    }

    // TODO: Handle real zlib-compressed data (from git)
    return error.ZlibNotImplemented;
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
    tag: void, // TODO
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

        // Compress (currently stores uncompressed - TODO: implement zlib)
        const compressed = try compressData(self.allocator, data_to_compress.items);
        defer self.allocator.free(compressed);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(compressed);

        return oid;
    }

    /// Read object by SHA-1
    pub fn read(self: *ObjectStore, oid: hash_mod.Sha1) !Object {
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

        // Decompress (currently handles uncompressed marker - TODO: implement zlib)
        const decompressed = try decompressData(self.allocator, compressed);
        defer self.allocator.free(decompressed);

        // Parse header
        const null_pos = std.mem.indexOf(u8, decompressed, "\x00") orelse return error.InvalidObject;
        const header = decompressed[0..null_pos];
        const content = decompressed[null_pos + 1 ..];

        // Determine type
        if (std.mem.startsWith(u8, header, "blob ")) {
            return Object{ .blob = blob.parse(content) };
        } else if (std.mem.startsWith(u8, header, "tree ")) {
            return Object{ .tree = try tree.parse(self.allocator, content) };
        } else if (std.mem.startsWith(u8, header, "commit ")) {
            return Object{ .commit = try commit.parse(self.allocator, content) };
        }

        return error.UnknownObjectType;
    }
};

test "object store compression helpers" {
    const allocator = std.testing.allocator;

    const data = "Hello, Git!";
    const compressed = try compressData(allocator, data);
    defer allocator.free(compressed);

    const decompressed = try decompressData(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(data, decompressed);
}
