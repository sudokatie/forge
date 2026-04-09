// Conflict types and helpers

const std = @import("std");
const hash_mod = @import("../object/hash.zig");

/// Conflict marker strings
pub const ConflictMarker = struct {
    pub const OURS_START = "<<<<<<<";
    pub const BASE_START = "|||||||";
    pub const SEPARATOR = "=======";
    pub const THEIRS_END = ">>>>>>>";
};

/// A conflicting entry in the index
pub const ConflictEntry = struct {
    /// File path
    path: []const u8,
    /// Stage 1: Common ancestor (base)
    base: ?hash_mod.Sha1,
    /// Stage 2: Current branch (ours)
    ours: ?hash_mod.Sha1,
    /// Stage 3: Other branch (theirs)
    theirs: ?hash_mod.Sha1,
    /// Mode for base version
    base_mode: u32,
    /// Mode for ours version
    ours_mode: u32,
    /// Mode for theirs version
    theirs_mode: u32,

    /// Check if this is a modify/delete conflict
    pub fn isModifyDelete(self: ConflictEntry) bool {
        return (self.ours == null) != (self.theirs == null);
    }

    /// Check if this is an add/add conflict
    pub fn isAddAdd(self: ConflictEntry) bool {
        return self.base == null and self.ours != null and self.theirs != null;
    }

    /// Check if this is a modify/modify conflict
    pub fn isModifyModify(self: ConflictEntry) bool {
        return self.base != null and self.ours != null and self.theirs != null;
    }
};

/// Conflict hunk in file content
pub const ConflictHunk = struct {
    /// Start line (0-indexed)
    start: usize,
    /// Number of lines in conflict region
    len: usize,
    /// Base lines (for diff3 style)
    base_lines: []const []const u8,
    /// Our lines
    ours_lines: []const []const u8,
    /// Their lines
    theirs_lines: []const []const u8,
};

/// Parse conflict markers from a file and extract hunks
pub fn parseConflicts(allocator: std.mem.Allocator, content: []const u8) ![]ConflictHunk {
    var hunks = std.ArrayList(ConflictHunk).init(allocator);
    errdefer hunks.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;
    var in_conflict = false;
    var conflict_start: usize = 0;
    var section: enum { ours, base, theirs } = .ours;
    var ours_lines = std.ArrayList([]const u8).init(allocator);
    var base_lines = std.ArrayList([]const u8).init(allocator);
    var theirs_lines = std.ArrayList([]const u8).init(allocator);

    defer {
        ours_lines.deinit();
        base_lines.deinit();
        theirs_lines.deinit();
    }

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, ConflictMarker.OURS_START)) {
            in_conflict = true;
            conflict_start = line_num;
            section = .ours;
            ours_lines.clearRetainingCapacity();
            base_lines.clearRetainingCapacity();
            theirs_lines.clearRetainingCapacity();
        } else if (in_conflict and std.mem.startsWith(u8, line, ConflictMarker.BASE_START)) {
            section = .base;
        } else if (in_conflict and std.mem.startsWith(u8, line, ConflictMarker.SEPARATOR)) {
            section = .theirs;
        } else if (in_conflict and std.mem.startsWith(u8, line, ConflictMarker.THEIRS_END)) {
            // End of conflict - record hunk
            try hunks.append(.{
                .start = conflict_start,
                .len = line_num - conflict_start + 1,
                .base_lines = try allocator.dupe([]const u8, base_lines.items),
                .ours_lines = try allocator.dupe([]const u8, ours_lines.items),
                .theirs_lines = try allocator.dupe([]const u8, theirs_lines.items),
            });
            in_conflict = false;
        } else if (in_conflict) {
            const line_copy = try allocator.dupe(u8, line);
            switch (section) {
                .ours => try ours_lines.append(line_copy),
                .base => try base_lines.append(line_copy),
                .theirs => try theirs_lines.append(line_copy),
            }
        }
        line_num += 1;
    }

    return hunks.toOwnedSlice();
}

/// Check if content contains conflict markers
pub fn hasConflicts(content: []const u8) bool {
    return std.mem.indexOf(u8, content, ConflictMarker.OURS_START) != null;
}

test "hasConflicts detection" {
    const clean = "normal file content\nwithout any conflicts\n";
    try std.testing.expect(!hasConflicts(clean));

    const conflicted =
        \\some content
        \\<<<<<<< HEAD
        \\our changes
        \\=======
        \\their changes
        \\>>>>>>> feature
        \\more content
    ;
    try std.testing.expect(hasConflicts(conflicted));
}

test "conflict entry types" {
    // Modify/modify
    const mm = ConflictEntry{
        .path = "file.txt",
        .base = [_]u8{1} ** 20,
        .ours = [_]u8{2} ** 20,
        .theirs = [_]u8{3} ** 20,
        .base_mode = 0o100644,
        .ours_mode = 0o100644,
        .theirs_mode = 0o100644,
    };
    try std.testing.expect(mm.isModifyModify());
    try std.testing.expect(!mm.isAddAdd());
    try std.testing.expect(!mm.isModifyDelete());

    // Add/add
    const aa = ConflictEntry{
        .path = "new.txt",
        .base = null,
        .ours = [_]u8{2} ** 20,
        .theirs = [_]u8{3} ** 20,
        .base_mode = 0,
        .ours_mode = 0o100644,
        .theirs_mode = 0o100644,
    };
    try std.testing.expect(aa.isAddAdd());
    try std.testing.expect(!aa.isModifyModify());

    // Modify/delete
    const md = ConflictEntry{
        .path = "deleted.txt",
        .base = [_]u8{1} ** 20,
        .ours = [_]u8{2} ** 20,
        .theirs = null,
        .base_mode = 0o100644,
        .ours_mode = 0o100644,
        .theirs_mode = 0,
    };
    try std.testing.expect(md.isModifyDelete());
}
