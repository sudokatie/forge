// Git index (staging area) implementation

const std = @import("std");
const hash_mod = @import("../object/hash.zig");

/// Index entry - represents a staged file
pub const IndexEntry = struct {
    /// Stat data
    ctime_s: u32,
    ctime_ns: u32,
    mtime_s: u32,
    mtime_ns: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u32,

    /// Object SHA-1
    sha: hash_mod.Sha1,

    /// Flags (includes name length in lower 12 bits)
    flags: u16,

    /// File path (relative to repo root)
    path: []const u8,

    /// Parse entry from binary data, returns entry and bytes consumed
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !struct { entry: IndexEntry, size: usize } {
        if (data.len < 62) return error.EntryTooShort;

        const entry = IndexEntry{
            .ctime_s = std.mem.readInt(u32, data[0..4], .big),
            .ctime_ns = std.mem.readInt(u32, data[4..8], .big),
            .mtime_s = std.mem.readInt(u32, data[8..12], .big),
            .mtime_ns = std.mem.readInt(u32, data[12..16], .big),
            .dev = std.mem.readInt(u32, data[16..20], .big),
            .ino = std.mem.readInt(u32, data[20..24], .big),
            .mode = std.mem.readInt(u32, data[24..28], .big),
            .uid = std.mem.readInt(u32, data[28..32], .big),
            .gid = std.mem.readInt(u32, data[32..36], .big),
            .size = std.mem.readInt(u32, data[36..40], .big),
            .sha = data[40..60].*,
            .flags = std.mem.readInt(u16, data[60..62], .big),
            .path = undefined,
        };

        // Name length is in lower 12 bits of flags
        const name_len = entry.flags & 0xFFF;
        if (data.len < 62 + name_len) return error.EntryTooShort;

        // Path is null-terminated
        const path_end = std.mem.indexOf(u8, data[62..], "\x00") orelse name_len;
        const path = try allocator.dupe(u8, data[62 .. 62 + path_end]);

        // Entry is padded to 8-byte boundary (62 + path + 1 null + padding)
        const entry_len = 62 + path_end + 1;
        const padded_len = (entry_len + 7) & ~@as(usize, 7);

        var result = entry;
        result.path = path;

        return .{ .entry = result, .size = padded_len };
    }

    /// Serialize entry to binary format
    pub fn serialize(self: IndexEntry, allocator: std.mem.Allocator) ![]u8 {
        const path_len = self.path.len;
        const entry_len = 62 + path_len + 1;
        const padded_len = (entry_len + 7) & ~@as(usize, 7);

        const buf = try allocator.alloc(u8, padded_len);
        @memset(buf, 0);

        std.mem.writeInt(u32, buf[0..4], self.ctime_s, .big);
        std.mem.writeInt(u32, buf[4..8], self.ctime_ns, .big);
        std.mem.writeInt(u32, buf[8..12], self.mtime_s, .big);
        std.mem.writeInt(u32, buf[12..16], self.mtime_ns, .big);
        std.mem.writeInt(u32, buf[16..20], self.dev, .big);
        std.mem.writeInt(u32, buf[20..24], self.ino, .big);
        std.mem.writeInt(u32, buf[24..28], self.mode, .big);
        std.mem.writeInt(u32, buf[28..32], self.uid, .big);
        std.mem.writeInt(u32, buf[32..36], self.gid, .big);
        std.mem.writeInt(u32, buf[36..40], self.size, .big);
        @memcpy(buf[40..60], &self.sha);

        // Flags: name length in lower 12 bits
        const flags = self.flags | @as(u16, @intCast(@min(path_len, 0xFFF)));
        std.mem.writeInt(u16, buf[60..62], flags, .big);

        @memcpy(buf[62 .. 62 + path_len], self.path);

        return buf;
    }
};

/// Git index file
pub const Index = struct {
    entries: []IndexEntry,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{
            .entries = &.{},
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
        if (version != 2 and version != 3) return error.UnsupportedVersion;

        const entry_count = std.mem.readInt(u32, data[8..12], .big);

        var entries: std.ArrayList(IndexEntry) = .empty;
        errdefer {
            for (entries.items) |e| allocator.free(e.path);
            entries.deinit(allocator);
        }

        var pos: usize = 12;
        for (0..entry_count) |_| {
            const result = try IndexEntry.parse(allocator, data[pos..]);
            try entries.append(allocator, result.entry);
            pos += result.size;
        }

        return Index{
            .entries = try entries.toOwnedSlice(allocator),
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
        std.mem.writeInt(u32, &version_buf, 2, .big);
        try result.appendSlice(self.allocator, &version_buf);
        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, @intCast(self.entries.len), .big);
        try result.appendSlice(self.allocator, &count_buf);

        // Entries
        for (self.entries) |entry| {
            const entry_data = try entry.serialize(self.allocator);
            defer self.allocator.free(entry_data);
            try result.appendSlice(self.allocator, entry_data);
        }

        // Checksum
        const sha = hash_mod.hash(result.items);
        try result.appendSlice(self.allocator, &sha);

        return try result.toOwnedSlice(self.allocator);
    }

    /// Add or update an entry
    pub fn add(self: *Index, entry: IndexEntry) !void {
        // Find existing entry with same path
        for (self.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, entry.path)) {
                self.allocator.free(e.path);
                self.entries[i] = entry;
                return;
            }
        }

        // Insert in sorted order
        var entries: std.ArrayList(IndexEntry) = .empty;
        try entries.appendSlice(self.allocator, self.entries);

        var insert_pos: usize = entries.items.len;
        for (entries.items, 0..) |e, i| {
            if (std.mem.lessThan(u8, entry.path, e.path)) {
                insert_pos = i;
                break;
            }
        }

        try entries.insert(self.allocator, insert_pos, entry);

        if (self.entries.len > 0) {
            self.allocator.free(self.entries);
        }
        self.entries = try entries.toOwnedSlice(self.allocator);
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
