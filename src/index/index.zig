// Git index (staging area) implementation

const std = @import("std");
const hash_mod = @import("../object/hash.zig");
pub const entry = @import("entry.zig");
pub const IndexEntry = entry.IndexEntry;

// Extension signatures
const EXT_TREE_CACHE: [4]u8 = "TREE".*;
const EXT_RESOLVE_UNDO: [4]u8 = "REUC".*;
const EXT_EOIE: [4]u8 = "EOIE".*; // End of Index Entry

/// Tree cache entry for a directory
pub const TreeCacheEntry = struct {
    path: []const u8, // Directory path (empty = root)
    entry_count: i32, // -1 if invalidated
    subtree_count: u32,
    sha: ?hash_mod.Sha1, // null if invalidated

    pub fn isValid(self: TreeCacheEntry) bool {
        return self.entry_count >= 0 and self.sha != null;
    }
};

/// Tree cache extension (TREE)
pub const TreeCache = struct {
    entries: []TreeCacheEntry,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TreeCache {
        return .{
            .entries = &.{},
            .allocator = allocator,
        };
    }

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !TreeCache {
        var entries: std.ArrayList(TreeCacheEntry) = .empty;
        errdefer {
            for (entries.items) |e| allocator.free(e.path);
            entries.deinit(allocator);
        }

        var pos: usize = 0;
        while (pos < data.len) {
            // Path (NUL-terminated)
            const path_end = std.mem.indexOf(u8, data[pos..], "\x00") orelse break;
            const path = try allocator.dupe(u8, data[pos .. pos + path_end]);
            pos += path_end + 1;

            // Entry count + space + subtree count + newline
            const line_end = std.mem.indexOf(u8, data[pos..], "\n") orelse break;
            const line = data[pos .. pos + line_end];
            pos += line_end + 1;

            var parts = std.mem.splitSequence(u8, line, " ");
            const entry_count_str = parts.next() orelse continue;
            const subtree_count_str = parts.next() orelse continue;

            const entry_count = std.fmt.parseInt(i32, entry_count_str, 10) catch -1;
            const subtree_count = std.fmt.parseInt(u32, subtree_count_str, 10) catch 0;

            var sha: ?hash_mod.Sha1 = null;
            if (entry_count >= 0 and pos + 20 <= data.len) {
                sha = data[pos..][0..20].*;
                pos += 20;
            }

            try entries.append(allocator, .{
                .path = path,
                .entry_count = entry_count,
                .subtree_count = subtree_count,
                .sha = sha,
            });
        }

        return TreeCache{
            .entries = try entries.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn serialize(self: *TreeCache, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        for (self.entries) |e| {
            try result.appendSlice(allocator, e.path);
            try result.append(allocator, 0);

            var buf: [32]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{d} {d}\n", .{ e.entry_count, e.subtree_count }) catch continue;
            try result.appendSlice(allocator, line);

            if (e.sha) |sha| {
                try result.appendSlice(allocator, &sha);
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Invalidate cache for a path and all its parents
    pub fn invalidate(self: *TreeCache, path: []const u8) void {
        for (self.entries) |*e| {
            if (std.mem.startsWith(u8, path, e.path)) {
                e.entry_count = -1;
                e.sha = null;
            }
        }
    }

    pub fn deinit(self: *TreeCache) void {
        for (self.entries) |e| {
            self.allocator.free(e.path);
        }
        if (self.entries.len > 0) {
            self.allocator.free(self.entries);
        }
    }
};

/// Resolve-undo entry (for conflict resolution)
pub const ResolveUndoEntry = struct {
    path: []const u8,
    stages: [3]?ResolveUndoStage, // Stages 1, 2, 3
};

pub const ResolveUndoStage = struct {
    mode: u32,
    sha: hash_mod.Sha1,
};

/// Resolve-undo extension (REUC)
pub const ResolveUndo = struct {
    entries: []ResolveUndoEntry,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ResolveUndo {
        return .{
            .entries = &.{},
            .allocator = allocator,
        };
    }

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !ResolveUndo {
        var entries: std.ArrayList(ResolveUndoEntry) = .empty;
        errdefer {
            for (entries.items) |e| allocator.free(e.path);
            entries.deinit(allocator);
        }

        var pos: usize = 0;
        while (pos < data.len) {
            // Path (NUL-terminated)
            const path_end = std.mem.indexOf(u8, data[pos..], "\x00") orelse break;
            const path = try allocator.dupe(u8, data[pos .. pos + path_end]);
            pos += path_end + 1;

            // Three octal modes (NUL-terminated each)
            var stages: [3]?ResolveUndoStage = .{ null, null, null };
            var modes: [3]u32 = .{ 0, 0, 0 };

            for (0..3) |i| {
                const mode_end = std.mem.indexOf(u8, data[pos..], "\x00") orelse break;
                modes[i] = std.fmt.parseInt(u32, data[pos .. pos + mode_end], 8) catch 0;
                pos += mode_end + 1;
            }

            // SHA-1 for each non-zero mode
            for (0..3) |i| {
                if (modes[i] != 0 and pos + 20 <= data.len) {
                    stages[i] = .{
                        .mode = modes[i],
                        .sha = data[pos..][0..20].*,
                    };
                    pos += 20;
                }
            }

            try entries.append(allocator, .{
                .path = path,
                .stages = stages,
            });
        }

        return ResolveUndo{
            .entries = try entries.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn serialize(self: *ResolveUndo, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        for (self.entries) |e| {
            try result.appendSlice(allocator, e.path);
            try result.append(allocator, 0);

            // Write modes
            for (e.stages) |stage| {
                if (stage) |s| {
                    var buf: [16]u8 = undefined;
                    const mode_str = std.fmt.bufPrint(&buf, "{o}", .{s.mode}) catch "0";
                    try result.appendSlice(allocator, mode_str);
                } else {
                    try result.append(allocator, '0');
                }
                try result.append(allocator, 0);
            }

            // Write SHAs for non-zero modes
            for (e.stages) |stage| {
                if (stage) |s| {
                    try result.appendSlice(allocator, &s.sha);
                }
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Add entry to resolve-undo when resolving a conflict
    pub fn add(self: *ResolveUndo, resolve_entry: ResolveUndoEntry) !void {
        var entries: std.ArrayList(ResolveUndoEntry) = .empty;
        try entries.appendSlice(self.allocator, self.entries);
        try entries.append(self.allocator, resolve_entry);

        if (self.entries.len > 0) {
            self.allocator.free(self.entries);
        }
        self.entries = try entries.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *ResolveUndo) void {
        for (self.entries) |e| {
            self.allocator.free(e.path);
        }
        if (self.entries.len > 0) {
            self.allocator.free(self.entries);
        }
    }
};

/// Git index file with extension support
pub const Index = struct {
    entries: []IndexEntry,
    tree_cache: ?TreeCache,
    resolve_undo: ?ResolveUndo,
    version: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{
            .entries = &.{},
            .tree_cache = null,
            .resolve_undo = null,
            .version = 2,
            .allocator = allocator,
        };
    }

    /// Read index from .git/index
    pub fn read(allocator: std.mem.Allocator, git_dir: []const u8) !Index {
        const path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
        defer allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                return Index.init(allocator);
            }
            return err;
        };
        defer allocator.free(content);

        return try parse(allocator, content);
    }

    /// Parse index from binary data
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Index {
        if (data.len < 12) return error.IndexTooShort;

        // Header: "DIRC" + version + entry count
        if (!std.mem.eql(u8, data[0..4], "DIRC")) return error.InvalidSignature;

        const version = std.mem.readInt(u32, data[4..8], .big);
        if (version != 2 and version != 3 and version != 4) return error.UnsupportedVersion;

        const entry_count = std.mem.readInt(u32, data[8..12], .big);

        var entries: std.ArrayList(IndexEntry) = .empty;
        errdefer {
            for (entries.items) |e| allocator.free(e.path);
            entries.deinit(allocator);
        }

        var pos: usize = 12;
        for (0..entry_count) |_| {
            const result = try IndexEntry.parse(allocator, data[pos..], version);
            try entries.append(allocator, result.entry);
            pos += result.size;
        }

        // Parse extensions (before final SHA-1 checksum)
        var tree_cache: ?TreeCache = null;
        var resolve_undo: ?ResolveUndo = null;

        // Extensions are between entries and final 20-byte checksum
        const checksum_start = data.len -| 20;
        while (pos + 8 <= checksum_start) {
            const sig = data[pos..][0..4];
            const ext_size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
            pos += 8;

            if (pos + ext_size > checksum_start) break;

            const ext_data = data[pos .. pos + ext_size];

            if (std.mem.eql(u8, sig, &EXT_TREE_CACHE)) {
                tree_cache = try TreeCache.parse(allocator, ext_data);
            } else if (std.mem.eql(u8, sig, &EXT_RESOLVE_UNDO)) {
                resolve_undo = try ResolveUndo.parse(allocator, ext_data);
            }
            // Ignore unknown extensions

            pos += ext_size;
        }

        return Index{
            .entries = try entries.toOwnedSlice(allocator),
            .tree_cache = tree_cache,
            .resolve_undo = resolve_undo,
            .version = version,
            .allocator = allocator,
        };
    }

    /// Write index to .git/index
    pub fn write(self: *Index, git_dir: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/index", .{git_dir});
        defer self.allocator.free(path);

        const data = try self.serialize();
        defer self.allocator.free(data);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    /// Serialize index to binary format
    pub fn serialize(self: *Index) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        // Header
        try result.appendSlice(self.allocator, "DIRC");
        var version_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &version_buf, self.version, .big);
        try result.appendSlice(self.allocator, &version_buf);
        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, @intCast(self.entries.len), .big);
        try result.appendSlice(self.allocator, &count_buf);

        // Entries
        for (self.entries) |ent| {
            const entry_data = try ent.serialize(self.allocator, self.version);
            defer self.allocator.free(entry_data);
            try result.appendSlice(self.allocator, entry_data);
        }

        // Extensions
        if (self.tree_cache) |*tc| {
            const tc_data = try tc.serialize(self.allocator);
            defer self.allocator.free(tc_data);

            try result.appendSlice(self.allocator, &EXT_TREE_CACHE);
            var size_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &size_buf, @intCast(tc_data.len), .big);
            try result.appendSlice(self.allocator, &size_buf);
            try result.appendSlice(self.allocator, tc_data);
        }

        if (self.resolve_undo) |*ru| {
            const ru_data = try ru.serialize(self.allocator);
            defer self.allocator.free(ru_data);

            try result.appendSlice(self.allocator, &EXT_RESOLVE_UNDO);
            var size_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &size_buf, @intCast(ru_data.len), .big);
            try result.appendSlice(self.allocator, &size_buf);
            try result.appendSlice(self.allocator, ru_data);
        }

        // Checksum
        const sha = hash_mod.hash(result.items);
        try result.appendSlice(self.allocator, &sha);

        return try result.toOwnedSlice(self.allocator);
    }

    /// Add or update an entry
    pub fn add(self: *Index, new_entry: IndexEntry) !void {
        // Find existing entry with same path
        for (self.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, new_entry.path)) {
                self.allocator.free(e.path);
                self.entries[i] = new_entry;
                return;
            }
        }

        // Insert in sorted order
        var entries: std.ArrayList(IndexEntry) = .empty;
        try entries.appendSlice(self.allocator, self.entries);

        var insert_pos: usize = entries.items.len;
        for (entries.items, 0..) |e, i| {
            if (std.mem.lessThan(u8, new_entry.path, e.path)) {
                insert_pos = i;
                break;
            }
        }

        try entries.insert(self.allocator, insert_pos, new_entry);

        if (self.entries.len > 0) {
            self.allocator.free(self.entries);
        }
        self.entries = try entries.toOwnedSlice(self.allocator);

        // Invalidate tree cache for this path
        if (self.tree_cache) |*tc| {
            tc.invalidate(new_entry.path);
        }
    }

    /// Remove an entry by path
    pub fn remove(self: *Index, path: []const u8) bool {
        for (self.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, path)) {
                self.allocator.free(e.path);
                // Shift remaining entries
                for (i..self.entries.len - 1) |j| {
                    self.entries[j] = self.entries[j + 1];
                }
                self.entries = self.entries[0 .. self.entries.len - 1];

                // Invalidate tree cache
                if (self.tree_cache) |*tc| {
                    tc.invalidate(path);
                }
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *Index) void {
        for (self.entries) |e| {
            self.allocator.free(e.path);
        }
        if (self.entries.len > 0) {
            self.allocator.free(self.entries);
        }
        if (self.tree_cache) |*tc| {
            tc.deinit();
        }
        if (self.resolve_undo) |*ru| {
            ru.deinit();
        }
    }
};

// Tests
test "empty index" {
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    try std.testing.expectEqual(@as(usize, 0), idx.entries.len);
}

test "index header parse" {
    // DIRC version 2, 0 entries, followed by SHA
    var data: [32]u8 = undefined;
    @memcpy(data[0..4], "DIRC");
    std.mem.writeInt(u32, data[4..8], 2, .big);
    std.mem.writeInt(u32, data[8..12], 0, .big);
    // Rest is checksum (we don't verify in parse currently)

    const allocator = std.testing.allocator;
    var idx = try Index.parse(allocator, &data);
    defer idx.deinit();

    try std.testing.expectEqual(@as(usize, 0), idx.entries.len);
}

test "index add entry" {
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();

    const sha = hash_mod.hash("test content");
    try idx.add(.{
        .ctime_s = 0,
        .ctime_ns = 0,
        .mtime_s = 0,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .size = 12,
        .sha = sha,
        .flags = 0,
        .path = try allocator.dupe(u8, "test.txt"),
    });

    try std.testing.expectEqual(@as(usize, 1), idx.entries.len);
    try std.testing.expectEqualStrings("test.txt", idx.entries[0].path);
}
