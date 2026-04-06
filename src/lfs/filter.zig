const std = @import("std");
const Allocator = std.mem.Allocator;
const Pointer = @import("pointer.zig").Pointer;
const ObjectStore = @import("api.zig").ObjectStore;
const Client = @import("api.zig").Client;

/// LFS clean filter - converts file content to pointer
/// Used when staging files for commit
pub const CleanFilter = struct {
    allocator: Allocator,
    store: *ObjectStore,
    client: ?*Client,
    /// Minimum file size to convert to LFS (default 100KB)
    min_size: u64 = 100 * 1024,

    const Self = @This();

    /// Process content through clean filter
    /// Returns pointer content if file should be LFS-tracked, otherwise returns original
    pub fn process(self: *Self, content: []const u8) ![]u8 {
        // Don't convert if already a pointer
        if (Pointer.isPointer(content)) {
            return self.allocator.dupe(u8, content);
        }

        // Don't convert small files
        if (content.len < self.min_size) {
            return self.allocator.dupe(u8, content);
        }

        // Create pointer and store content
        const ptr = Pointer.fromContent(content);

        // Store locally
        try self.store.writeObject(&ptr.oid, content);

        // Upload to server if client available
        if (self.client) |client| {
            const objects = [_]Client.BatchObject{.{
                .oid = &ptr.oid,
                .size = ptr.size,
            }};
            const response = client.batchUpload(&objects) catch |err| {
                // Log but don't fail - upload can happen later
                std.log.warn("LFS upload failed: {}", .{err});
                return try ptr.format(self.allocator);
            };
            _ = response;
            // TODO: actually upload content via action.upload.href
        }

        return try ptr.format(self.allocator);
    }
};

/// LFS smudge filter - converts pointer to actual content
/// Used when checking out files from the repo
pub const SmudgeFilter = struct {
    allocator: Allocator,
    store: *ObjectStore,
    client: ?*Client,

    const Self = @This();

    /// Process content through smudge filter
    /// Returns actual file content if pointer, otherwise returns original
    pub fn process(self: *Self, content: []const u8) ![]u8 {
        // If not a pointer, return as-is
        if (!Pointer.isPointer(content)) {
            return self.allocator.dupe(u8, content);
        }

        const ptr = try Pointer.parse(content);

        // Try local store first
        if (self.store.hasObject(&ptr.oid)) {
            return try self.store.readObject(&ptr.oid);
        }

        // Try to download from server
        if (self.client) |client| {
            const objects = [_]Client.BatchObject{.{
                .oid = &ptr.oid,
                .size = ptr.size,
            }};
            const response = client.batchDownload(&objects) catch |err| {
                std.log.warn("LFS download failed: {}", .{err});
                // Return pointer content if download fails
                return self.allocator.dupe(u8, content);
            };
            _ = response;
            // TODO: actually download content via action.download.href
            // and store locally before returning
        }

        // Return pointer content if we can't get the actual content
        return self.allocator.dupe(u8, content);
    }
};

/// Check if a path matches LFS tracking patterns
pub fn isTracked(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (matchPattern(path, pattern)) {
            return true;
        }
    }
    return false;
}

/// Simple glob pattern matching (supports * wildcard)
fn matchPattern(path: []const u8, pattern: []const u8) bool {
    // Handle exact match
    if (std.mem.eql(u8, path, pattern)) {
        return true;
    }

    // Handle extension patterns like "*.bin"
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const ext = pattern[1..]; // ".bin"
        return std.mem.endsWith(u8, path, ext);
    }

    // Handle directory patterns like "large/**"
    if (std.mem.endsWith(u8, pattern, "/**")) {
        const dir = pattern[0 .. pattern.len - 3]; // "large/"
        return std.mem.startsWith(u8, path, dir);
    }

    return false;
}

/// Parse .gitattributes for LFS tracked patterns
pub fn parseGitAttributes(allocator: Allocator, content: []const u8) ![][]const u8 {
    var patterns = std.ArrayListUnmanaged([]const u8){};
    errdefer patterns.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Skip comments and empty lines
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Look for "filter=lfs" attribute
        if (std.mem.indexOf(u8, trimmed, "filter=lfs")) |_| {
            // Extract pattern (first whitespace-separated token)
            var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
            if (tokens.next()) |pattern| {
                try patterns.append(allocator, try allocator.dupe(u8, pattern));
            }
        }
    }

    return try patterns.toOwnedSlice(allocator);
}

// Tests
test "matchPattern - exact match" {
    try std.testing.expect(matchPattern("file.bin", "file.bin"));
    try std.testing.expect(!matchPattern("file.txt", "file.bin"));
}

test "matchPattern - extension pattern" {
    try std.testing.expect(matchPattern("file.bin", "*.bin"));
    try std.testing.expect(matchPattern("path/to/file.bin", "*.bin"));
    try std.testing.expect(!matchPattern("file.txt", "*.bin"));
}

test "matchPattern - directory pattern" {
    try std.testing.expect(matchPattern("large/file.bin", "large/**"));
    try std.testing.expect(matchPattern("large/subdir/file.bin", "large/**"));
    try std.testing.expect(!matchPattern("other/file.bin", "large/**"));
}

test "parseGitAttributes" {
    const allocator = std.testing.allocator;
    const content =
        \\# Git LFS tracked files
        \\*.bin filter=lfs diff=lfs merge=lfs -text
        \\*.zip filter=lfs diff=lfs merge=lfs -text
        \\large/** filter=lfs diff=lfs merge=lfs -text
        \\# Not LFS
        \\*.txt text
        \\
    ;

    const patterns = try parseGitAttributes(allocator, content);
    defer {
        for (patterns) |p| allocator.free(p);
        allocator.free(patterns);
    }

    try std.testing.expectEqual(@as(usize, 3), patterns.len);
    try std.testing.expectEqualStrings("*.bin", patterns[0]);
    try std.testing.expectEqualStrings("*.zip", patterns[1]);
    try std.testing.expectEqualStrings("large/**", patterns[2]);
}

test "isTracked" {
    const patterns = &[_][]const u8{ "*.bin", "*.zip", "large/**" };

    try std.testing.expect(isTracked("file.bin", patterns));
    try std.testing.expect(isTracked("archive.zip", patterns));
    try std.testing.expect(isTracked("large/file.dat", patterns));
    try std.testing.expect(!isTracked("file.txt", patterns));
}
