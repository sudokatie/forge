// Myers diff algorithm implementation

const std = @import("std");

pub const EditType = enum {
    equal,
    insert,
    delete,
};

pub const Edit = struct {
    kind: EditType,
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
};

/// Compute line-based diff between two texts
pub fn diff(allocator: std.mem.Allocator, old_text: []const u8, new_text: []const u8) ![]Edit {
    // Split into lines
    var old_lines: std.ArrayList([]const u8) = .empty;
    defer old_lines.deinit(allocator);
    var new_lines: std.ArrayList([]const u8) = .empty;
    defer new_lines.deinit(allocator);

    var old_iter = std.mem.splitSequence(u8, old_text, "\n");
    while (old_iter.next()) |line| {
        try old_lines.append(allocator, line);
    }

    var new_iter = std.mem.splitSequence(u8, new_text, "\n");
    while (new_iter.next()) |line| {
        try new_lines.append(allocator, line);
    }

    return try diffLines(allocator, old_lines.items, new_lines.items);
}

/// Diff two arrays of lines using simple LCS-based approach
fn diffLines(allocator: std.mem.Allocator, old: []const []const u8, new: []const []const u8) ![]Edit {
    var edits: std.ArrayList(Edit) = .empty;
    errdefer edits.deinit(allocator);

    var old_idx: usize = 0;
    var new_idx: usize = 0;

    while (old_idx < old.len or new_idx < new.len) {
        // Find matching lines
        if (old_idx < old.len and new_idx < new.len and std.mem.eql(u8, old[old_idx], new[new_idx])) {
            // Equal - advance both
            var count: usize = 0;
            const start_old = old_idx;
            const start_new = new_idx;
            while (old_idx < old.len and new_idx < new.len and std.mem.eql(u8, old[old_idx], new[new_idx])) {
                count += 1;
                old_idx += 1;
                new_idx += 1;
            }
            try edits.append(allocator, .{
                .kind = .equal,
                .old_start = start_old,
                .old_count = count,
                .new_start = start_new,
                .new_count = count,
            });
        } else if (new_idx < new.len and (old_idx >= old.len or !lineExistsAhead(old[old_idx..], new[new_idx]))) {
            // Insert
            try edits.append(allocator, .{
                .kind = .insert,
                .old_start = old_idx,
                .old_count = 0,
                .new_start = new_idx,
                .new_count = 1,
            });
            new_idx += 1;
        } else if (old_idx < old.len) {
            // Delete
            try edits.append(allocator, .{
                .kind = .delete,
                .old_start = old_idx,
                .old_count = 1,
                .new_start = new_idx,
                .new_count = 0,
            });
            old_idx += 1;
        }
    }

    return try edits.toOwnedSlice(allocator);
}

fn lineExistsAhead(lines: []const []const u8, target: []const u8) bool {
    for (lines) |line| {
        if (std.mem.eql(u8, line, target)) return true;
    }
    return false;
}

/// Generate unified diff output
pub fn unifiedDiff(allocator: std.mem.Allocator, old_name: []const u8, new_name: []const u8, old_text: []const u8, new_text: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    const writer = result.writer(allocator);

    // Header
    try writer.print("--- {s}\n", .{old_name});
    try writer.print("+++ {s}\n", .{new_name});

    // Split into lines
    var old_lines: std.ArrayList([]const u8) = .empty;
    defer old_lines.deinit(allocator);
    var new_lines: std.ArrayList([]const u8) = .empty;
    defer new_lines.deinit(allocator);

    var old_iter = std.mem.splitSequence(u8, old_text, "\n");
    while (old_iter.next()) |line| {
        try old_lines.append(allocator, line);
    }

    var new_iter = std.mem.splitSequence(u8, new_text, "\n");
    while (new_iter.next()) |line| {
        try new_lines.append(allocator, line);
    }

    const edits = try diffLines(allocator, old_lines.items, new_lines.items);
    defer allocator.free(edits);

    // Generate hunks
    var i: usize = 0;
    while (i < edits.len) {
        // Skip equal sections until we find a change
        while (i < edits.len and edits[i].kind == .equal) {
            i += 1;
        }
        if (i >= edits.len) break;

        // Find hunk boundaries (include 3 lines context)
        const context: usize = 3;
        var hunk_start = i;
        if (hunk_start > 0) {
            hunk_start = if (edits[hunk_start - 1].old_count > context)
                hunk_start
            else
                hunk_start -| 1;
        }

        // Find end of hunk
        var hunk_end = i;
        while (hunk_end < edits.len) {
            if (edits[hunk_end].kind != .equal) {
                hunk_end += 1;
            } else if (hunk_end + 1 < edits.len and edits[hunk_end].old_count <= context * 2) {
                hunk_end += 1;
            } else {
                break;
            }
        }

        // Calculate hunk header
        var old_start: usize = 0;
        var old_count: usize = 0;
        var new_start: usize = 0;
        var new_count: usize = 0;

        for (hunk_start..hunk_end) |j| {
            if (j == hunk_start) {
                old_start = edits[j].old_start + 1;
                new_start = edits[j].new_start + 1;
            }
            old_count += edits[j].old_count;
            new_count += edits[j].new_count;
        }

        try writer.print("@@ -{d},{d} +{d},{d} @@\n", .{ old_start, old_count, new_start, new_count });

        // Output hunk content
        for (hunk_start..hunk_end) |j| {
            const edit = edits[j];
            switch (edit.kind) {
                .equal => {
                    for (0..edit.old_count) |k| {
                        try writer.print(" {s}\n", .{old_lines.items[edit.old_start + k]});
                    }
                },
                .delete => {
                    for (0..edit.old_count) |k| {
                        try writer.print("-{s}\n", .{old_lines.items[edit.old_start + k]});
                    }
                },
                .insert => {
                    for (0..edit.new_count) |k| {
                        try writer.print("+{s}\n", .{new_lines.items[edit.new_start + k]});
                    }
                },
            }
        }

        i = hunk_end;
    }

    return try result.toOwnedSlice(allocator);
}

// Tests
test "diff empty" {
    const allocator = std.testing.allocator;
    const edits = try diff(allocator, "", "");
    defer allocator.free(edits);
    try std.testing.expectEqual(@as(usize, 1), edits.len); // One empty equal
}

test "diff insert" {
    const allocator = std.testing.allocator;
    const edits = try diff(allocator, "", "hello");
    defer allocator.free(edits);
    try std.testing.expect(edits.len > 0);
}

test "diff delete" {
    const allocator = std.testing.allocator;
    const edits = try diff(allocator, "hello", "");
    defer allocator.free(edits);
    try std.testing.expect(edits.len > 0);
}

test "diff mixed" {
    const allocator = std.testing.allocator;
    const old = "line1\nline2\nline3";
    const new = "line1\nmodified\nline3";
    const edits = try diff(allocator, old, new);
    defer allocator.free(edits);
    try std.testing.expect(edits.len > 0);
}
