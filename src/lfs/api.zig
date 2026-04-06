const std = @import("std");
const Allocator = std.mem.Allocator;
const Pointer = @import("pointer.zig").Pointer;

/// LFS API client for batch operations
pub const Client = struct {
    allocator: Allocator,
    /// Base URL for LFS API (e.g., "https://github.com/owner/repo.git/info/lfs")
    endpoint: []const u8,
    /// Optional auth token
    auth_token: ?[]const u8,

    const Self = @This();

    /// Initialize a new LFS client
    pub fn init(allocator: Allocator, endpoint: []const u8, auth_token: ?[]const u8) Self {
        return Self{
            .allocator = allocator,
            .endpoint = endpoint,
            .auth_token = auth_token,
        };
    }

    /// Object in a batch request
    pub const BatchObject = struct {
        oid: []const u8,
        size: u64,
    };

    /// Action returned in batch response
    pub const Action = struct {
        href: []const u8,
        header: ?std.StringHashMap([]const u8) = null,
        expires_in: ?i64 = null,
        expires_at: ?[]const u8 = null,
    };

    /// Object in a batch response
    pub const ResponseObject = struct {
        oid: []const u8,
        size: u64,
        authenticated: bool = false,
        actions: ?struct {
            download: ?Action = null,
            upload: ?Action = null,
            verify: ?Action = null,
        } = null,
        @"error": ?struct {
            code: i32,
            message: []const u8,
        } = null,
    };

    /// Batch response from LFS server
    pub const BatchResponse = struct {
        transfer: []const u8 = "basic",
        objects: []ResponseObject,
        hash_algo: []const u8 = "sha256",
    };

    /// Request download URLs for objects
    pub fn batchDownload(self: *Self, objects: []const BatchObject) !BatchResponse {
        return self.batch("download", objects);
    }

    /// Request upload URLs for objects
    pub fn batchUpload(self: *Self, objects: []const BatchObject) !BatchResponse {
        return self.batch("upload", objects);
    }

    /// Perform batch API request
    fn batch(self: *Self, operation: []const u8, objects: []const BatchObject) !BatchResponse {
        _ = self;
        _ = operation;
        _ = objects;
        // HTTP client implementation would go here
        // For now, return a stub error
        return error.NotImplemented;
    }

    /// Download object content from LFS server
    pub fn download(self: *Self, action: *const Action) ![]u8 {
        _ = self;
        _ = action;
        return error.NotImplemented;
    }

    /// Upload object content to LFS server
    pub fn upload(self: *Self, action: *const Action, content: []const u8) !void {
        _ = self;
        _ = action;
        _ = content;
        return error.NotImplemented;
    }

    /// Derive LFS endpoint from git remote URL
    pub fn endpointFromRemote(allocator: Allocator, remote_url: []const u8) ![]u8 {
        // Remove .git suffix if present, then add /info/lfs
        var url = remote_url;
        if (std.mem.endsWith(u8, url, ".git")) {
            url = url[0 .. url.len - 4];
        }
        return std.fmt.allocPrint(allocator, "{s}.git/info/lfs", .{url});
    }
};

/// LFS object storage for local cache
pub const ObjectStore = struct {
    allocator: Allocator,
    /// Path to .git/lfs/objects directory
    objects_dir: []const u8,

    const Self = @This();

    /// Initialize object store
    pub fn init(allocator: Allocator, git_dir: []const u8) !Self {
        const objects_dir = try std.fs.path.join(allocator, &.{ git_dir, "lfs", "objects" });
        return Self{
            .allocator = allocator,
            .objects_dir = objects_dir,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.objects_dir);
    }

    /// Get path to object file (creates directories if needed)
    pub fn objectPath(self: *const Self, oid: []const u8) ![]u8 {
        if (oid.len != 64) return error.InvalidOid;

        // LFS stores objects in subdirectories: objects/ab/cd/abcdef...
        const dir1 = oid[0..2];
        const dir2 = oid[2..4];

        return std.fs.path.join(self.allocator, &.{ self.objects_dir, dir1, dir2, oid });
    }

    /// Check if object exists in local store
    pub fn hasObject(self: *const Self, oid: []const u8) bool {
        const path = self.objectPath(oid) catch return false;
        defer self.allocator.free(path);

        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    /// Read object from local store
    pub fn readObject(self: *const Self, oid: []const u8) ![]u8 {
        const path = try self.objectPath(oid);
        defer self.allocator.free(path);

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        return file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
    }

    /// Write object to local store
    pub fn writeObject(self: *const Self, oid: []const u8, content: []const u8) !void {
        const path = try self.objectPath(oid);
        defer self.allocator.free(path);

        // Ensure parent directories exist
        const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Write atomically by writing to temp then renaming
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();

        try file.writeAll(content);
        try std.fs.renameAbsolute(tmp_path, path);
    }
};

// Tests
test "endpointFromRemote - HTTPS with .git" {
    const allocator = std.testing.allocator;
    const endpoint = try Client.endpointFromRemote(allocator, "https://github.com/owner/repo.git");
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://github.com/owner/repo.git/info/lfs", endpoint);
}

test "endpointFromRemote - HTTPS without .git" {
    const allocator = std.testing.allocator;
    const endpoint = try Client.endpointFromRemote(allocator, "https://github.com/owner/repo");
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://github.com/owner/repo.git/info/lfs", endpoint);
}

test "objectPath format" {
    const allocator = std.testing.allocator;
    var store = try ObjectStore.init(allocator, "/repo/.git");
    defer store.deinit();

    const oid = "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393";
    const path = try store.objectPath(oid);
    defer allocator.free(path);

    try std.testing.expectEqualStrings(
        "/repo/.git/lfs/objects/4d/7a/4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393",
        path,
    );
}

test "objectPath invalid oid" {
    const allocator = std.testing.allocator;
    var store = try ObjectStore.init(allocator, "/repo/.git");
    defer store.deinit();

    try std.testing.expectError(error.InvalidOid, store.objectPath("short"));
}
