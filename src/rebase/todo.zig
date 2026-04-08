// Rebase TODO list parsing and management
// Handles the interactive rebase instruction file

const std = @import("std");
const hash_mod = @import("../object/hash.zig");

/// Actions that can be performed on a commit during rebase
pub const TodoAction = enum {
    pick,      // Use commit as-is
    reword,    // Use commit but edit message
    edit,      // Use commit but stop for amending
    squash,    // Meld into previous commit, keep message
    fixup,     // Like squash but discard message
    drop,      // Remove commit entirely
    exec,      // Run shell command (the commit field is the command)
    label,     // Mark current position (for complex rebase)
    reset,     // Reset HEAD to label
    merge,     // Create merge commit

    pub fn fromString(s: []const u8) ?TodoAction {
        if (std.mem.eql(u8, s, "pick") or std.mem.eql(u8, s, "p")) return .pick;
        if (std.mem.eql(u8, s, "reword") or std.mem.eql(u8, s, "r")) return .reword;
        if (std.mem.eql(u8, s, "edit") or std.mem.eql(u8, s, "e")) return .edit;
        if (std.mem.eql(u8, s, "squash") or std.mem.eql(u8, s, "s")) return .squash;
        if (std.mem.eql(u8, s, "fixup") or std.mem.eql(u8, s, "f")) return .fixup;
        if (std.mem.eql(u8, s, "drop") or std.mem.eql(u8, s, "d")) return .drop;
        if (std.mem.eql(u8, s, "exec") or std.mem.eql(u8, s, "x")) return .exec;
        if (std.mem.eql(u8, s, "label") or std.mem.eql(u8, s, "l")) return .label;
        if (std.mem.eql(u8, s, "reset") or std.mem.eql(u8, s, "t")) return .reset;
        if (std.mem.eql(u8, s, "merge") or std.mem.eql(u8, s, "m")) return .merge;
        return null;
    }

    pub fn toString(self: TodoAction) []const u8 {
        return switch (self) {
            .pick => "pick",
            .reword => "reword",
            .edit => "edit",
            .squash => "squash",
            .fixup => "fixup",
            .drop => "drop",
            .exec => "exec",
            .label => "label",
            .reset => "reset",
            .merge => "merge",
        };
    }

    /// Returns true if this action requires a commit hash
    pub fn needsCommit(self: TodoAction) bool {
        return switch (self) {
            .pick, .reword, .edit, .squash, .fixup, .drop => true,
            .exec, .label, .reset, .merge => false,
        };
    }
};

/// A single item in the rebase todo list
pub const TodoItem = struct {
    action: TodoAction,
    commit: ?hash_mod.Sha1,  // null for exec/label/reset
    arg: []const u8,        // commit subject or exec command or label name
    original_line: []const u8,

    pub fn format(
        self: TodoItem,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}", .{self.action.toString()});
        if (self.commit) |hash| {
            try writer.print(" {s}", .{hash.toHex()[0..7]});
        }
        if (self.arg.len > 0) {
            try writer.print(" {s}", .{self.arg});
        }
    }
};

/// The complete todo list for an interactive rebase
pub const TodoList = struct {
    items: std.ArrayList(TodoItem),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .items = std.ArrayList(TodoItem).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit();
    }

    /// Parse a todo list from text (as edited by user)
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Self {
        var list = Self.init(allocator);
        errdefer list.deinit();

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            // Skip empty lines and comments
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            const item = try parseLine(trimmed, line);
            try list.items.append(item);
        }

        return list;
    }

    fn parseLine(trimmed: []const u8, original: []const u8) !TodoItem {
        var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');

        const action_str = parts.next() orelse return error.InvalidTodoLine;
        const action = TodoAction.fromString(action_str) orelse return error.UnknownAction;

        var commit: ?hash_mod.Sha1 = null;
        var arg: []const u8 = "";

        if (action.needsCommit()) {
            const hash_str = parts.next() orelse return error.MissingCommit;
            // Allow abbreviated hashes (we store what we get, engine resolves)
            if (hash_str.len < 4) return error.InvalidCommitHash;

            // For now, pad short hashes with zeros - engine will resolve
            var full_hash: [40]u8 = undefined;
            @memset(&full_hash, '0');
            @memcpy(full_hash[0..@min(hash_str.len, 40)], hash_str[0..@min(hash_str.len, 40)]);
            commit = hash_mod.Sha1.fromHex(&full_hash) catch return error.InvalidCommitHash;

            // Rest is the subject/arg
            arg = parts.rest();
        } else {
            // For exec/label/reset, rest is the arg
            arg = parts.rest();
        }

        return TodoItem{
            .action = action,
            .commit = commit,
            .arg = arg,
            .original_line = original,
        };
    }

    /// Generate the todo list text (for writing to file)
    pub fn toText(self: *const Self, writer: anytype) !void {
        for (self.items.items) |item| {
            try writer.print("{s}", .{item.action.toString()});
            if (item.commit) |hash| {
                try writer.print(" {s}", .{hash.toHex()[0..7]});
            }
            if (item.arg.len > 0) {
                try writer.print(" {s}", .{item.arg});
            }
            try writer.writeByte('\n');
        }
    }

    /// Generate todo list with help comments
    pub fn toTextWithHelp(self: *const Self, writer: anytype) !void {
        try self.toText(writer);
        try writer.writeAll(
            \\
            \\# Rebase instruction file
            \\#
            \\# Commands:
            \\# p, pick <commit> = use commit
            \\# r, reword <commit> = use commit, but edit the commit message
            \\# e, edit <commit> = use commit, but stop for amending
            \\# s, squash <commit> = use commit, but meld into previous commit
            \\# f, fixup <commit> = like "squash", but discard this commit's log message
            \\# d, drop <commit> = remove commit
            \\# x, exec <command> = run command (the rest of the line) using shell
            \\#
            \\# These lines can be re-ordered; they are executed from top to bottom.
            \\# If you remove a line here THAT COMMIT WILL BE LOST.
            \\# However, if you remove everything, the rebase will be aborted.
            \\
        );
    }

    /// Create a default todo list from a commit range (newest first, reversed for rebase)
    pub fn fromCommitRange(
        allocator: std.mem.Allocator,
        commits: []const hash_mod.Sha1,
        subjects: []const []const u8,
    ) !Self {
        if (commits.len != subjects.len) return error.MismatchedLengths;

        var list = Self.init(allocator);
        errdefer list.deinit();

        // Commits come newest-first, but rebase applies oldest-first
        var i: usize = commits.len;
        while (i > 0) {
            i -= 1;
            try list.items.append(.{
                .action = .pick,
                .commit = commits[i],
                .arg = subjects[i],
                .original_line = "",
            });
        }

        return list;
    }
};

test "parse action strings" {
    try std.testing.expectEqual(TodoAction.pick, TodoAction.fromString("pick").?);
    try std.testing.expectEqual(TodoAction.pick, TodoAction.fromString("p").?);
    try std.testing.expectEqual(TodoAction.squash, TodoAction.fromString("squash").?);
    try std.testing.expectEqual(TodoAction.squash, TodoAction.fromString("s").?);
    try std.testing.expectEqual(TodoAction.fixup, TodoAction.fromString("f").?);
    try std.testing.expect(TodoAction.fromString("unknown") == null);
}

test "parse todo line" {
    const text =
        \\pick abc1234 Add feature
        \\reword def5678 Fix bug
        \\# This is a comment
        \\squash 1234567 Small fix
        \\
        \\drop fedcba9 Remove test
        \\exec make test
    ;

    const allocator = std.testing.allocator;
    var list = try TodoList.parse(allocator, text);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 5), list.items.items.len);
    try std.testing.expectEqual(TodoAction.pick, list.items.items[0].action);
    try std.testing.expectEqual(TodoAction.reword, list.items.items[1].action);
    try std.testing.expectEqual(TodoAction.squash, list.items.items[2].action);
    try std.testing.expectEqual(TodoAction.drop, list.items.items[3].action);
    try std.testing.expectEqual(TodoAction.exec, list.items.items[4].action);
}

test "todo item formatting" {
    var buf: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const item = TodoItem{
        .action = .pick,
        .commit = hash_mod.Sha1.fromHex("abc1234567890123456789012345678901234567") catch unreachable,
        .arg = "Add feature",
        .original_line = "",
    };

    try writer.print("{}", .{item});
    try std.testing.expectEqualStrings("pick abc1234 Add feature", fbs.getWritten());
}

test "action needs commit" {
    try std.testing.expect(TodoAction.pick.needsCommit());
    try std.testing.expect(TodoAction.squash.needsCommit());
    try std.testing.expect(!TodoAction.exec.needsCommit());
    try std.testing.expect(!TodoAction.label.needsCommit());
}
