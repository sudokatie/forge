// Three-way merge algorithm
//
// Implements line-based three-way merge with conflict detection.

const std = @import("std");
const hash_mod = @import("../object/hash.zig");
const store_mod = @import("../object/store.zig");
const tree_mod = @import("../object/tree.zig");
const conflict = @import("conflict.zig");

/// Merge conflict style
pub const ConflictStyle = enum {
    /// Standard merge (shows ours and theirs)
    merge,
    /// Diff3 style (shows base, ours, and theirs)
    diff3,
};

/// Options for merge operation
pub const MergeOptions = struct {
    /// Conflict marker style
    style: ConflictStyle = .diff3,
    /// Label for ours side
    ours_label: []const u8 = "HEAD",
    /// Label for theirs side
    theirs_label: []const u8 = "incoming",
    /// Label for base (diff3 only)
    base_label: []const u8 = "base",
};

/// Result of a merge operation
pub const MergeResult = struct {
    /// Merged content (may contain conflict markers)
    content: []const u8,
    /// Whether there were conflicts
    has_conflicts: bool,
    /// Number of conflict regions
    conflict_count: usize,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *MergeResult) void {
        self.allocator.free(self.content);
    }
};

/// Line with its original index
const Line = struct {
    content: []const u8,
    index: usize,
};

/// A change region from LCS diff
const Change = struct {
    kind: enum { keep, add_ours, add_theirs, conflict },
    base_start: usize,
    base_end: usize,
    ours_start: usize,
    ours_end: usize,
    theirs_start: usize,
    theirs_end: usize,
};

/// Merge two versions against a common base
pub fn mergeBlobs(
    allocator: std.mem.Allocator,
    base_content: ?[]const u8,
    ours_content: []const u8,
    theirs_content: []const u8,
    options: MergeOptions,
) !MergeResult {
    const base = base_content orelse "";

    // Split into lines
    var base_lines = std.ArrayList([]const u8).init(allocator);
    defer base_lines.deinit();
    var ours_lines = std.ArrayList([]const u8).init(allocator);
    defer ours_lines.deinit();
    var theirs_lines = std.ArrayList([]const u8).init(allocator);
    defer theirs_lines.deinit();

    try splitLines(base, &base_lines);
    try splitLines(ours_content, &ours_lines);
    try splitLines(theirs_content, &theirs_lines);

    // Compute diffs from base to ours and base to theirs
    const ours_diff = try computeDiff(allocator, base_lines.items, ours_lines.items);
    defer allocator.free(ours_diff);
    const theirs_diff = try computeDiff(allocator, base_lines.items, theirs_lines.items);
    defer allocator.free(theirs_diff);

    // Merge the diffs
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var has_conflicts = false;
    var conflict_count: usize = 0;

    // Use a simple line-by-line merge approach
    var base_idx: usize = 0;
    var ours_idx: usize = 0;
    var theirs_idx: usize = 0;

    while (base_idx < base_lines.items.len or ours_idx < ours_lines.items.len or theirs_idx < theirs_lines.items.len) {
        const base_line = if (base_idx < base_lines.items.len) base_lines.items[base_idx] else null;
        const ours_line = if (ours_idx < ours_lines.items.len) ours_lines.items[ours_idx] else null;
        const theirs_line = if (theirs_idx < theirs_lines.items.len) theirs_lines.items[theirs_idx] else null;

        // Check for matching lines
        const ours_matches_base = if (base_line != null and ours_line != null) std.mem.eql(u8, base_line.?, ours_line.?) else false;
        const theirs_matches_base = if (base_line != null and theirs_line != null) std.mem.eql(u8, base_line.?, theirs_line.?) else false;
        const ours_matches_theirs = if (ours_line != null and theirs_line != null) std.mem.eql(u8, ours_line.?, theirs_line.?) else false;

        if (ours_matches_base and theirs_matches_base) {
            // All three match - use base/ours
            try result.appendSlice(base_line.?);
            try result.append('\n');
            base_idx += 1;
            ours_idx += 1;
            theirs_idx += 1;
        } else if (ours_matches_theirs) {
            // Ours and theirs match - use that (both made same change)
            try result.appendSlice(ours_line.?);
            try result.append('\n');
            if (ours_matches_base) base_idx += 1;
            ours_idx += 1;
            theirs_idx += 1;
        } else if (ours_matches_base and !theirs_matches_base) {
            // Only theirs changed - take theirs
            if (theirs_line) |line| {
                try result.appendSlice(line);
                try result.append('\n');
                theirs_idx += 1;
            }
            base_idx += 1;
            ours_idx += 1;
        } else if (!ours_matches_base and theirs_matches_base) {
            // Only ours changed - take ours
            if (ours_line) |line| {
                try result.appendSlice(line);
                try result.append('\n');
                ours_idx += 1;
            }
            base_idx += 1;
            theirs_idx += 1;
        } else {
            // Conflict - both sides changed differently
            has_conflicts = true;
            conflict_count += 1;

            // Find extent of conflict (how many consecutive conflicting lines)
            var ours_end = ours_idx;
            var theirs_end = theirs_idx;
            var base_end = base_idx;

            // Simple heuristic: conflict continues until we find matching lines again
            while (ours_end < ours_lines.items.len and theirs_end < theirs_lines.items.len) {
                const o = ours_lines.items[ours_end];
                const t = theirs_lines.items[theirs_end];
                if (std.mem.eql(u8, o, t)) break;
                ours_end += 1;
                theirs_end += 1;
                if (base_end < base_lines.items.len) base_end += 1;
            }

            // Write conflict markers
            try result.appendSlice(conflict.ConflictMarker.OURS_START);
            try result.append(' ');
            try result.appendSlice(options.ours_label);
            try result.append('\n');

            while (ours_idx < ours_end) : (ours_idx += 1) {
                try result.appendSlice(ours_lines.items[ours_idx]);
                try result.append('\n');
            }

            if (options.style == .diff3) {
                try result.appendSlice(conflict.ConflictMarker.BASE_START);
                try result.append(' ');
                try result.appendSlice(options.base_label);
                try result.append('\n');

                while (base_idx < base_end) : (base_idx += 1) {
                    try result.appendSlice(base_lines.items[base_idx]);
                    try result.append('\n');
                }
            } else {
                base_idx = base_end;
            }

            try result.appendSlice(conflict.ConflictMarker.SEPARATOR);
            try result.append('\n');

            while (theirs_idx < theirs_end) : (theirs_idx += 1) {
                try result.appendSlice(theirs_lines.items[theirs_idx]);
                try result.append('\n');
            }

            try result.appendSlice(conflict.ConflictMarker.THEIRS_END);
            try result.append(' ');
            try result.appendSlice(options.theirs_label);
            try result.append('\n');
        }
    }

    return .{
        .content = try result.toOwnedSlice(),
        .has_conflicts = has_conflicts,
        .conflict_count = conflict_count,
        .allocator = allocator,
    };
}

/// Merge trees recursively
pub fn mergeTrees(
    allocator: std.mem.Allocator,
    store: *store_mod.ObjectStore,
    base: ?hash_mod.Sha1,
    ours: hash_mod.Sha1,
    theirs: hash_mod.Sha1,
    options: MergeOptions,
) !struct { tree: hash_mod.Sha1, conflicts: []conflict.ConflictEntry } {
    _ = options;

    var conflicts = std.ArrayList(conflict.ConflictEntry).init(allocator);
    errdefer conflicts.deinit();

    // Load trees
    const base_entries = if (base) |b| blk: {
        const data = try store.read(allocator, b);
        defer allocator.free(data);
        break :blk try tree_mod.parse(allocator, data);
    } else &[_]tree_mod.Entry{};
    defer if (base != null) allocator.free(base_entries);

    const ours_data = try store.read(allocator, ours);
    defer allocator.free(ours_data);
    const ours_entries = try tree_mod.parse(allocator, ours_data);
    defer allocator.free(ours_entries);

    const theirs_data = try store.read(allocator, theirs);
    defer allocator.free(theirs_data);
    const theirs_entries = try tree_mod.parse(allocator, theirs_data);
    defer allocator.free(theirs_entries);

    // Build path -> entry maps
    var base_map = std.StringHashMap(tree_mod.Entry).init(allocator);
    defer base_map.deinit();
    for (base_entries) |e| {
        try base_map.put(e.name, e);
    }

    var ours_map = std.StringHashMap(tree_mod.Entry).init(allocator);
    defer ours_map.deinit();
    for (ours_entries) |e| {
        try ours_map.put(e.name, e);
    }

    var theirs_map = std.StringHashMap(tree_mod.Entry).init(allocator);
    defer theirs_map.deinit();
    for (theirs_entries) |e| {
        try theirs_map.put(e.name, e);
    }

    // Collect all paths
    var all_paths = std.StringHashMap(void).init(allocator);
    defer all_paths.deinit();
    for (base_entries) |e| try all_paths.put(e.name, {});
    for (ours_entries) |e| try all_paths.put(e.name, {});
    for (theirs_entries) |e| try all_paths.put(e.name, {});

    // Merge result entries
    var result_entries = std.ArrayList(tree_mod.Entry).init(allocator);
    defer result_entries.deinit();

    var path_iter = all_paths.keyIterator();
    while (path_iter.next()) |path| {
        const base_entry = base_map.get(path.*);
        const ours_entry = ours_map.get(path.*);
        const theirs_entry = theirs_map.get(path.*);

        const base_sha = if (base_entry) |e| e.sha else null;
        const ours_sha = if (ours_entry) |e| e.sha else null;
        const theirs_sha = if (theirs_entry) |e| e.sha else null;

        // Check for conflicts
        if (ours_sha != null and theirs_sha != null) {
            const ours_eq = std.mem.eql(u8, &ours_sha.?, &theirs_sha.?);
            const ours_eq_base = if (base_sha) |b| std.mem.eql(u8, &ours_sha.?, &b) else false;
            const theirs_eq_base = if (base_sha) |b| std.mem.eql(u8, &theirs_sha.?, &b) else false;

            if (ours_eq) {
                // Same change on both sides
                try result_entries.append(ours_entry.?);
            } else if (ours_eq_base and !theirs_eq_base) {
                // Only theirs changed
                try result_entries.append(theirs_entry.?);
            } else if (!ours_eq_base and theirs_eq_base) {
                // Only ours changed
                try result_entries.append(ours_entry.?);
            } else {
                // Conflict!
                try conflicts.append(.{
                    .path = try allocator.dupe(u8, path.*),
                    .base = base_sha,
                    .ours = ours_sha,
                    .theirs = theirs_sha,
                    .base_mode = if (base_entry) |e| e.mode else 0,
                    .ours_mode = if (ours_entry) |e| e.mode else 0,
                    .theirs_mode = if (theirs_entry) |e| e.mode else 0,
                });
                // Keep ours for now (caller will resolve)
                try result_entries.append(ours_entry.?);
            }
        } else if (ours_sha != null) {
            // Deleted in theirs
            if (base_sha != null) {
                const ours_eq_base = std.mem.eql(u8, &ours_sha.?, &base_sha.?);
                if (!ours_eq_base) {
                    // Modified in ours, deleted in theirs = conflict
                    try conflicts.append(.{
                        .path = try allocator.dupe(u8, path.*),
                        .base = base_sha,
                        .ours = ours_sha,
                        .theirs = null,
                        .base_mode = if (base_entry) |e| e.mode else 0,
                        .ours_mode = if (ours_entry) |e| e.mode else 0,
                        .theirs_mode = 0,
                    });
                }
                // If unchanged in ours, accept deletion
            } else {
                // Added in ours only
                try result_entries.append(ours_entry.?);
            }
        } else if (theirs_sha != null) {
            // Deleted in ours
            if (base_sha != null) {
                const theirs_eq_base = std.mem.eql(u8, &theirs_sha.?, &base_sha.?);
                if (!theirs_eq_base) {
                    // Modified in theirs, deleted in ours = conflict
                    try conflicts.append(.{
                        .path = try allocator.dupe(u8, path.*),
                        .base = base_sha,
                        .ours = null,
                        .theirs = theirs_sha,
                        .base_mode = if (base_entry) |e| e.mode else 0,
                        .ours_mode = 0,
                        .theirs_mode = if (theirs_entry) |e| e.mode else 0,
                    });
                }
                // If unchanged in theirs, accept deletion
            } else {
                // Added in theirs only
                try result_entries.append(theirs_entry.?);
            }
        }
        // Both null means deleted in both - do nothing
    }

    // Sort entries by name and write tree
    std.mem.sort(tree_mod.Entry, result_entries.items, {}, struct {
        fn cmp(_: void, a: tree_mod.Entry, b: tree_mod.Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.cmp);

    const tree_hash = try tree_mod.writeTree(allocator, store, result_entries.items);

    return .{
        .tree = tree_hash,
        .conflicts = try conflicts.toOwnedSlice(),
    };
}

/// Split content into lines
fn splitLines(content: []const u8, list: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        try list.append(line);
    }
    // Remove last empty line if content ends with newline
    if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) {
        _ = list.pop();
    }
}

/// Simple diff - returns array of bools indicating which base lines are kept
fn computeDiff(allocator: std.mem.Allocator, base: []const []const u8, other: []const []const u8) ![]bool {
    const result = try allocator.alloc(bool, base.len);
    @memset(result, false);

    // Simple O(n*m) check for matching lines
    for (base, 0..) |base_line, i| {
        for (other) |other_line| {
            if (std.mem.eql(u8, base_line, other_line)) {
                result[i] = true;
                break;
            }
        }
    }

    return result;
}

// Tests

test "merge identical content" {
    const allocator = std.testing.allocator;

    const base = "line1\nline2\nline3\n";
    const ours = "line1\nline2\nline3\n";
    const theirs = "line1\nline2\nline3\n";

    var result = try mergeBlobs(allocator, base, ours, theirs, .{});
    defer result.deinit();

    try std.testing.expect(!result.has_conflicts);
    try std.testing.expectEqual(@as(usize, 0), result.conflict_count);
}

test "merge clean - only ours changed" {
    const allocator = std.testing.allocator;

    const base = "line1\nline2\nline3\n";
    const ours = "line1\nmodified\nline3\n";
    const theirs = "line1\nline2\nline3\n";

    var result = try mergeBlobs(allocator, base, ours, theirs, .{});
    defer result.deinit();

    try std.testing.expect(!result.has_conflicts);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "modified") != null);
}

test "merge clean - only theirs changed" {
    const allocator = std.testing.allocator;

    const base = "line1\nline2\nline3\n";
    const ours = "line1\nline2\nline3\n";
    const theirs = "line1\nchanged\nline3\n";

    var result = try mergeBlobs(allocator, base, ours, theirs, .{});
    defer result.deinit();

    try std.testing.expect(!result.has_conflicts);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "changed") != null);
}

test "merge conflict - both changed same line differently" {
    const allocator = std.testing.allocator;

    const base = "line1\nline2\nline3\n";
    const ours = "line1\nours change\nline3\n";
    const theirs = "line1\ntheirs change\nline3\n";

    var result = try mergeBlobs(allocator, base, ours, theirs, .{});
    defer result.deinit();

    try std.testing.expect(result.has_conflicts);
    try std.testing.expect(result.conflict_count > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.content, conflict.ConflictMarker.OURS_START) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, conflict.ConflictMarker.SEPARATOR) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, conflict.ConflictMarker.THEIRS_END) != null);
}

test "merge no base (add/add)" {
    const allocator = std.testing.allocator;

    const ours = "our content\n";
    const theirs = "their content\n";

    var result = try mergeBlobs(allocator, null, ours, theirs, .{});
    defer result.deinit();

    try std.testing.expect(result.has_conflicts);
}
