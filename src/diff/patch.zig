// Unified diff format generation

const std = @import("std");
const myers = @import("myers.zig");

pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: []HunkLine,
};

pub const HunkLine = struct {
    kind: enum { context, add, delete },
    content: []const u8,
};

pub const Patch = struct {
    old_name: []const u8,
    new_name: []const u8,
    hunks: []Hunk,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Patch) void {
        for (self.hunks) |hunk| {
            self.allocator.free(hunk.lines);
        }
        self.allocator.free(self.hunks);
    }
};

/// Generate unified diff between two texts
pub fn unifiedDiff(
    allocator: std.mem.Allocator,
    old_name: []const u8,
    new_name: []const u8,
    old_text: []const u8,
    new_text: []const u8,
) ![]u8 {
    return myers.unifiedDiff(allocator, old_name, new_name, old_text, new_text);
}

/// Generate unified diff with custom context lines
pub fn unifiedDiffWithContext(
    allocator: std.mem.Allocator,
    old_name: []const u8,
    new_name: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    context_lines: usize,
) ![]u8 {
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

    const edits = try myers.diff(allocator, old_text, new_text);
    defer allocator.free(edits);

    // Generate hunks with specified context
    var i: usize = 0;
    while (i < edits.len) {
        // Skip equal sections until we find a change
        while (i < edits.len and edits[i].kind == .equal) {
            i += 1;
        }
        if (i >= edits.len) break;

        // Find hunk boundaries with context
        var hunk_start = i;
        if (hunk_start > 0 and edits[hunk_start - 1].kind == .equal) {
            const prev_equal = edits[hunk_start - 1];
            if (prev_equal.old_count > context_lines) {
                // Include only last N context lines
            } else {
                hunk_start -= 1;
            }
        }

        // Find end of hunk
        var hunk_end = i;
        while (hunk_end < edits.len) {
            if (edits[hunk_end].kind != .equal) {
                hunk_end += 1;
            } else if (hunk_end + 1 < edits.len and edits[hunk_end].old_count <= context_lines * 2) {
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
                        if (edit.old_start + k < old_lines.items.len) {
                            try writer.print(" {s}\n", .{old_lines.items[edit.old_start + k]});
                        }
                    }
                },
                .delete => {
                    for (0..edit.old_count) |k| {
                        if (edit.old_start + k < old_lines.items.len) {
                            try writer.print("-{s}\n", .{old_lines.items[edit.old_start + k]});
                        }
                    }
                },
                .insert => {
                    for (0..edit.new_count) |k| {
                        if (edit.new_start + k < new_lines.items.len) {
                            try writer.print("+{s}\n", .{new_lines.items[edit.new_start + k]});
                        }
                    }
                },
            }
        }

        i = hunk_end;
    }

    return try result.toOwnedSlice(allocator);
}

/// Generate Git-style diff header
pub fn gitDiffHeader(
    allocator: std.mem.Allocator,
    old_path: []const u8,
    new_path: []const u8,
    old_sha: ?[40]u8,
    new_sha: ?[40]u8,
    old_mode: ?u32,
    new_mode: ?u32,
) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    const writer = result.writer(allocator);

    try writer.print("diff --git a/{s} b/{s}\n", .{ old_path, new_path });

    if (old_mode != null and new_mode != null and old_mode.? != new_mode.?) {
        try writer.print("old mode {o}\n", .{old_mode.?});
        try writer.print("new mode {o}\n", .{new_mode.?});
    }

    if (old_sha != null and new_sha != null) {
        try writer.print("index {s}..{s}", .{ old_sha.?[0..7], new_sha.?[0..7] });
        if (new_mode) |mode| {
            try writer.print(" {o}", .{mode});
        }
        try writer.writeAll("\n");
    }

    try writer.print("--- a/{s}\n", .{old_path});
    try writer.print("+++ b/{s}\n", .{new_path});

    return try result.toOwnedSlice(allocator);
}

/// Apply a unified diff patch to text
pub fn applyPatch(allocator: std.mem.Allocator, original: []const u8, patch_text: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var original_lines: std.ArrayList([]const u8) = .empty;
    defer original_lines.deinit(allocator);

    var orig_iter = std.mem.splitSequence(u8, original, "\n");
    while (orig_iter.next()) |line| {
        try original_lines.append(allocator, line);
    }

    var line_idx: usize = 0;
    var patch_lines = std.mem.splitSequence(u8, patch_text, "\n");

    while (patch_lines.next()) |line| {
        // Skip header lines
        if (std.mem.startsWith(u8, line, "---") or
            std.mem.startsWith(u8, line, "+++") or
            std.mem.startsWith(u8, line, "diff"))
        {
            continue;
        }

        // Parse hunk header
        if (std.mem.startsWith(u8, line, "@@")) {
            // Format: @@ -old_start,old_count +new_start,new_count @@
            var parts = std.mem.splitSequence(u8, line, " ");
            _ = parts.next(); // @@
            const old_range = parts.next() orelse continue;
            _ = old_range; // -N,M

            continue;
        }

        // Apply line
        if (line.len == 0) {
            if (line_idx < original_lines.items.len) {
                try result.appendSlice(allocator, original_lines.items[line_idx]);
                try result.append(allocator, '\n');
                line_idx += 1;
            }
        } else if (line[0] == ' ') {
            // Context line - copy from original
            if (line_idx < original_lines.items.len) {
                try result.appendSlice(allocator, original_lines.items[line_idx]);
                try result.append(allocator, '\n');
                line_idx += 1;
            }
        } else if (line[0] == '-') {
            // Delete line - skip in original
            line_idx += 1;
        } else if (line[0] == '+') {
            // Add line
            try result.appendSlice(allocator, line[1..]);
            try result.append(allocator, '\n');
        }
    }

    // Copy remaining lines
    while (line_idx < original_lines.items.len) {
        try result.appendSlice(allocator, original_lines.items[line_idx]);
        if (line_idx + 1 < original_lines.items.len) {
            try result.append(allocator, '\n');
        }
        line_idx += 1;
    }

    return try result.toOwnedSlice(allocator);
}

// Tests
test "unified diff basic" {
    const allocator = std.testing.allocator;

    const old = "line1\nline2\nline3";
    const new = "line1\nmodified\nline3";

    const diff_output = try unifiedDiff(allocator, "a.txt", "b.txt", old, new);
    defer allocator.free(diff_output);

    try std.testing.expect(std.mem.indexOf(u8, diff_output, "--- a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff_output, "+++ b.txt") != null);
}

test "git diff header" {
    const allocator = std.testing.allocator;

    const header = try gitDiffHeader(
        allocator,
        "test.txt",
        "test.txt",
        "abc1234abc1234abc1234abc1234abc1234abc12".*,
        "def5678def5678def5678def5678def5678def56".*,
        0o100644,
        0o100644,
    );
    defer allocator.free(header);

    try std.testing.expect(std.mem.indexOf(u8, header, "diff --git") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "index abc1234..def5678") != null);
}
