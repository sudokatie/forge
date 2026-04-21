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
            var response = client.batchUpload(&objects) catch |err| {
                // Log but don't fail - upload can happen later
                std.log.warn("LFS batch upload request failed: {}", .{err});
                return try ptr.format(self.allocator);
            };
            defer client.freeBatchResponse(&response);

            // Upload each object that needs uploading
            for (response.objects) |obj| {
                if (obj.@"error") |e| {
                    std.log.warn("LFS server error for {s}: {s}", .{ obj.oid, e.message });
                    continue;
                }

                if (obj.actions) |actions| {
                    // Upload the content
                    if (actions.upload) |upload_action| {
                        client.upload(&upload_action, content) catch |err| {
                            std.log.warn("LFS upload failed for {s}: {}", .{ obj.oid, err });
                            continue;
                        };

                        // Verify upload if server provides verify action
                        if (actions.verify) |verify_action| {
                            client.verify(&verify_action, &ptr.oid, ptr.size) catch |err| {
                                std.log.warn("LFS verify failed for {s}: {}", .{ obj.oid, err });
                            };
                        }
                    }
                }
            }
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
            var response = client.batchDownload(&objects) catch |err| {
                std.log.warn("LFS batch download request failed: {}", .{err});
                // Return pointer content if download fails
                return self.allocator.dupe(u8, content);
            };
            defer client.freeBatchResponse(&response);

            // Download the object
            for (response.objects) |obj| {
                if (obj.@"error") |e| {
                    std.log.warn("LFS server error for {s}: {s}", .{ obj.oid, e.message });
                    continue;
                }

                if (obj.actions) |actions| {
                    if (actions.download) |download_action| {
                        const downloaded = client.download(&download_action) catch |err| {
                            std.log.warn("LFS download failed for {s}: {}", .{ obj.oid, err });
                            continue;
                        };
                        errdefer self.allocator.free(downloaded);

                        // Verify SHA-256 hash matches
                        if (!verifyHash(downloaded, &ptr.oid)) {
                            std.log.warn("LFS hash mismatch for {s}", .{obj.oid});
                            self.allocator.free(downloaded);
                            continue;
                        }

                        // Store locally for future use
                        self.store.writeObject(&ptr.oid, downloaded) catch |err| {
                            std.log.warn("Failed to cache LFS object {s}: {}", .{ obj.oid, err });
                        };

                        return downloaded;
                    }
                }
            }
        }

        // Return pointer content if we can't get the actual content
        return self.allocator.dupe(u8, content);
    }
};

/// Verify SHA-256 hash of content matches expected OID
fn verifyHash(content: []const u8, expected_oid: []const u8) bool {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);
    const digest = hasher.finalResult();

    // Convert to hex and compare
    const hex_chars = "0123456789abcdef";
    var computed_oid: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        computed_oid[i * 2] = hex_chars[byte >> 4];
        computed_oid[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    return std.mem.eql(u8, &computed_oid, expected_oid);
}

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

test "verifyHash - valid hash" {
    const content = "Hello, LFS!";
    // SHA-256 of "Hello, LFS!"
    const expected_oid = "969ada5a96b2d122a71a1d8da0f7cdf99ef19d46d5613e7be4ac07dbb6724bfa";
    try std.testing.expect(verifyHash(content, expected_oid));
}

test "verifyHash - invalid hash" {
    const content = "Hello, LFS!";
    const wrong_oid = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expect(!verifyHash(content, wrong_oid));
}

test "verifyHash - empty content" {
    const content = "";
    // SHA-256 of empty string
    const expected_oid = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try std.testing.expect(verifyHash(content, expected_oid));
}

test "CleanFilter - small file passthrough" {
    const allocator = std.testing.allocator;

    // Create a mock object store (won't actually write)
    var store = try ObjectStore.init(allocator, "/tmp/test-lfs");
    defer store.deinit();

    var filter = CleanFilter{
        .allocator = allocator,
        .store = &store,
        .client = null,
        .min_size = 100 * 1024, // 100KB minimum
    };

    const small_content = "This is a small file";
    const result = try filter.process(small_content);
    defer allocator.free(result);

    // Should return original content since it's below min_size
    try std.testing.expectEqualStrings(small_content, result);
}

test "CleanFilter - pointer passthrough" {
    const allocator = std.testing.allocator;

    var store = try ObjectStore.init(allocator, "/tmp/test-lfs");
    defer store.deinit();

    var filter = CleanFilter{
        .allocator = allocator,
        .store = &store,
        .client = null,
        .min_size = 0, // No minimum
    };

    const pointer_content =
        \\version https://git-lfs.github.com/spec/v1
        \\oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        \\size 12345
        \\
    ;

    const result = try filter.process(pointer_content);
    defer allocator.free(result);

    // Should return original pointer content unchanged
    try std.testing.expectEqualStrings(pointer_content, result);
}

test "SmudgeFilter - non-pointer passthrough" {
    const allocator = std.testing.allocator;

    var store = try ObjectStore.init(allocator, "/tmp/test-lfs");
    defer store.deinit();

    var filter = SmudgeFilter{
        .allocator = allocator,
        .store = &store,
        .client = null,
    };

    const regular_content = "This is regular file content";
    const result = try filter.process(regular_content);
    defer allocator.free(result);

    // Should return original content unchanged
    try std.testing.expectEqualStrings(regular_content, result);
}
