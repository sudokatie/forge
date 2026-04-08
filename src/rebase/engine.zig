// Rebase Engine
// Executes the rebase operations and manages state

const std = @import("std");
const hash_mod = @import("../object/hash.zig");
const store_mod = @import("../object/store.zig");
const commit_mod = @import("../object/commit.zig");
const refs_mod = @import("../refs/ref.zig");
const todo = @import("todo.zig");

pub const RebaseError = error{
    NotInRebase,
    AlreadyInRebase,
    ConflictDetected,
    NothingToCommit,
    InvalidState,
    CannotContinue,
    CherryPickFailed,
    OutOfMemory,
    IoError,
};

/// State of an in-progress rebase
pub const RebaseState = struct {
    /// The original branch/ref we're rebasing
    head_name: []const u8,
    /// The commit we started from
    orig_head: hash_mod.Sha1,
    /// The commit we're rebasing onto
    onto: hash_mod.Sha1,
    /// Current HEAD during rebase
    head: hash_mod.Sha1,
    /// Index of current item being processed (0-based)
    current: usize,
    /// Total number of items
    total: usize,
    /// Whether we're stopped for editing/conflict
    stopped: bool,
    /// Message for squash/fixup accumulation
    squash_msg: []const u8,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.head_name);
        if (self.squash_msg.len > 0) {
            self.allocator.free(self.squash_msg);
        }
    }

    /// Serialize state to string for persistence
    pub fn serialize(self: *const Self, writer: anytype) !void {
        try writer.print("head_name={s}\n", .{self.head_name});
        try writer.print("orig_head={s}\n", .{self.orig_head.toHex()});
        try writer.print("onto={s}\n", .{self.onto.toHex()});
        try writer.print("head={s}\n", .{self.head.toHex()});
        try writer.print("current={}\n", .{self.current});
        try writer.print("total={}\n", .{self.total});
        try writer.print("stopped={}\n", .{@intFromBool(self.stopped)});
    }

    /// Deserialize state from string
    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !Self {
        var state = Self{
            .head_name = "",
            .orig_head = undefined,
            .onto = undefined,
            .head = undefined,
            .current = 0,
            .total = 0,
            .stopped = false,
            .squash_msg = "",
            .allocator = allocator,
        };

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var kv = std.mem.splitScalar(u8, line, '=');
            const key = kv.next() orelse continue;
            const value = kv.rest();

            if (std.mem.eql(u8, key, "head_name")) {
                state.head_name = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "orig_head")) {
                if (value.len >= 40) {
                    state.orig_head = hash_mod.Sha1.fromHex(value[0..40].*) catch return error.InvalidState;
                }
            } else if (std.mem.eql(u8, key, "onto")) {
                if (value.len >= 40) {
                    state.onto = hash_mod.Sha1.fromHex(value[0..40].*) catch return error.InvalidState;
                }
            } else if (std.mem.eql(u8, key, "head")) {
                if (value.len >= 40) {
                    state.head = hash_mod.Sha1.fromHex(value[0..40].*) catch return error.InvalidState;
                }
            } else if (std.mem.eql(u8, key, "current")) {
                state.current = std.fmt.parseInt(usize, value, 10) catch 0;
            } else if (std.mem.eql(u8, key, "total")) {
                state.total = std.fmt.parseInt(usize, value, 10) catch 0;
            } else if (std.mem.eql(u8, key, "stopped")) {
                state.stopped = std.mem.eql(u8, value, "1");
            }
        }

        return state;
    }
};

/// Rebase engine manages the execution of a rebase
pub const RebaseEngine = struct {
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    store: *store_mod.ObjectStore,
    refs: *refs_mod.RefStore,

    const Self = @This();

    const REBASE_DIR = "rebase-merge";
    const TODO_FILE = "git-rebase-todo";
    const STATE_FILE = "state";
    const DONE_FILE = "done";
    const MSG_FILE = "message";
    const ORIG_HEAD_FILE = "orig-head";
    const HEAD_NAME_FILE = "head-name";

    pub fn init(
        allocator: std.mem.Allocator,
        git_dir: []const u8,
        store: *store_mod.ObjectStore,
        refs: *refs_mod.RefStore,
    ) Self {
        return .{
            .allocator = allocator,
            .git_dir = git_dir,
            .store = store,
            .refs = refs,
        };
    }

    /// Check if a rebase is in progress
    pub fn isInProgress(self: *Self) bool {
        const rebase_path = std.fs.path.join(self.allocator, &.{ self.git_dir, REBASE_DIR }) catch return false;
        defer self.allocator.free(rebase_path);

        std.fs.accessAbsolute(rebase_path, .{}) catch return false;
        return true;
    }

    /// Start an interactive rebase
    pub fn start(
        self: *Self,
        head_name: []const u8,
        orig_head: hash_mod.Sha1,
        onto: hash_mod.Sha1,
        commits: []const hash_mod.Sha1,
        subjects: []const []const u8,
    ) !void {
        if (self.isInProgress()) return error.AlreadyInRebase;

        // Create rebase directory
        const rebase_path = try std.fs.path.join(self.allocator, &.{ self.git_dir, REBASE_DIR });
        defer self.allocator.free(rebase_path);

        try std.fs.makeDirAbsolute(rebase_path);

        // Create initial todo list
        var todo_list = try todo.TodoList.fromCommitRange(self.allocator, commits, subjects);
        defer todo_list.deinit();

        // Write todo file
        const todo_path = try std.fs.path.join(self.allocator, &.{ rebase_path, TODO_FILE });
        defer self.allocator.free(todo_path);

        const todo_file = try std.fs.createFileAbsolute(todo_path, .{});
        defer todo_file.close();
        try todo_list.toTextWithHelp(todo_file.writer());

        // Write state
        const state = RebaseState{
            .head_name = head_name,
            .orig_head = orig_head,
            .onto = onto,
            .head = onto,
            .current = 0,
            .total = commits.len,
            .stopped = true, // Stopped for user to edit todo
            .squash_msg = "",
            .allocator = self.allocator,
        };

        const state_path = try std.fs.path.join(self.allocator, &.{ rebase_path, STATE_FILE });
        defer self.allocator.free(state_path);

        const state_file = try std.fs.createFileAbsolute(state_path, .{});
        defer state_file.close();
        try state.serialize(state_file.writer());

        // Detach HEAD to onto
        try self.refs.updateHead(onto);
    }

    /// Load current rebase state
    pub fn loadState(self: *Self) !RebaseState {
        if (!self.isInProgress()) return error.NotInRebase;

        const state_path = try std.fs.path.join(self.allocator, &.{ self.git_dir, REBASE_DIR, STATE_FILE });
        defer self.allocator.free(state_path);

        const state_file = try std.fs.openFileAbsolute(state_path, .{});
        defer state_file.close();

        const data = try state_file.readToEndAlloc(self.allocator, 4096);
        defer self.allocator.free(data);

        return RebaseState.deserialize(self.allocator, data);
    }

    /// Load current todo list
    pub fn loadTodo(self: *Self) !todo.TodoList {
        const todo_path = try std.fs.path.join(self.allocator, &.{ self.git_dir, REBASE_DIR, TODO_FILE });
        defer self.allocator.free(todo_path);

        const todo_file = try std.fs.openFileAbsolute(todo_path, .{});
        defer todo_file.close();

        const data = try todo_file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(data);

        return todo.TodoList.parse(self.allocator, data);
    }

    /// Continue rebase after user edit/conflict resolution
    pub fn continueRebase(self: *Self) !void {
        var state = try self.loadState();
        defer state.deinit();

        if (!state.stopped) return error.CannotContinue;

        var todo_list = try self.loadTodo();
        defer todo_list.deinit();

        try self.runTodo(&state, &todo_list);
    }

    /// Abort rebase, restore original state
    pub fn abort(self: *Self) !void {
        var state = try self.loadState();
        defer state.deinit();

        // Restore original HEAD
        try self.refs.updateSymbolicRef("HEAD", state.head_name);
        try self.refs.updateHead(state.orig_head);

        // Clean up rebase directory
        const rebase_path = try std.fs.path.join(self.allocator, &.{ self.git_dir, REBASE_DIR });
        defer self.allocator.free(rebase_path);

        try std.fs.deleteTreeAbsolute(rebase_path);
    }

    /// Skip current commit and continue
    pub fn skip(self: *Self) !void {
        var state = try self.loadState();
        defer state.deinit();

        state.current += 1;
        state.stopped = false;

        try self.saveState(&state);

        var todo_list = try self.loadTodo();
        defer todo_list.deinit();

        try self.runTodo(&state, &todo_list);
    }

    /// Run todo items starting from current position
    fn runTodo(self: *Self, state: *RebaseState, todo_list: *todo.TodoList) !void {
        while (state.current < todo_list.items.items.len) {
            const item = todo_list.items.items[state.current];

            const should_stop = try self.executeItem(item, state);
            if (should_stop) {
                state.stopped = true;
                try self.saveState(state);
                return;
            }

            state.current += 1;
        }

        // Rebase complete - restore branch ref
        try self.finish(state);
    }

    /// Execute a single todo item
    fn executeItem(self: *Self, item: todo.TodoItem, state: *RebaseState) !bool {
        return switch (item.action) {
            .pick => try self.cherryPick(item.commit.?, false, state),
            .reword => {
                _ = try self.cherryPick(item.commit.?, true, state);
                return true; // Always stop for reword
            },
            .edit => {
                _ = try self.cherryPick(item.commit.?, false, state);
                return true; // Stop for edit
            },
            .squash => try self.squash(item.commit.?, false, state),
            .fixup => try self.squash(item.commit.?, true, state),
            .drop => false, // Just skip
            .exec => try self.execCommand(item.arg),
            .label, .reset, .merge => false, // Not implemented in basic version
        };
    }

    /// Cherry-pick a commit onto current HEAD
    fn cherryPick(
        self: *Self,
        commit_hash: hash_mod.Sha1,
        reword: bool,
        state: *RebaseState,
    ) !bool {
        _ = reword;
        // Read commit
        const commit_data = try self.store.read(self.allocator, commit_hash);
        defer self.allocator.free(commit_data);

        const commit = try commit_mod.parse(self.allocator, commit_data);
        defer @constCast(&commit).deinit();

        // For a full implementation, we would:
        // 1. Compute diff between commit's parent and commit
        // 2. Apply that diff to current working tree
        // 3. Handle conflicts
        // 4. Create new commit with same message but new parent

        // For now, create the commit structure (actual tree ops need index support)
        const new_commit_hash = try self.createCommit(
            commit.tree,
            state.head,
            commit.author,
            commit.author_time,
            commit.author_tz,
            commit.message,
        );

        state.head = new_commit_hash;
        try self.refs.updateHead(new_commit_hash);

        return false;
    }

    /// Squash/fixup a commit
    fn squash(
        self: *Self,
        commit_hash: hash_mod.Sha1,
        discard_msg: bool,
        state: *RebaseState,
    ) !bool {
        _ = state;
        _ = discard_msg;
        // Read the commit to squash
        const commit_data = try self.store.read(self.allocator, commit_hash);
        defer self.allocator.free(commit_data);

        const commit = try commit_mod.parse(self.allocator, commit_data);
        defer @constCast(&commit).deinit();

        // For squash, we need to:
        // 1. Apply changes from this commit
        // 2. Amend the previous commit
        // This is simplified - full impl needs tree merging
        // TODO: Implement full squash with tree merging

        return false;
    }

    /// Execute a shell command
    fn execCommand(self: *Self, command: []const u8) !bool {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "/bin/sh", "-c", command },
        }) catch return true; // Stop on exec failure
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return result.term.Exited != 0; // Stop if command fails
    }

    /// Create a new commit object
    fn createCommit(
        self: *Self,
        tree: hash_mod.Sha1,
        parent: hash_mod.Sha1,
        author: []const u8,
        author_time: i64,
        author_tz: []const u8,
        message: []const u8,
    ) !hash_mod.Sha1 {
        // Build commit content
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const writer = buf.writer();
        try writer.print("tree {s}\n", .{tree.toHex()});
        try writer.print("parent {s}\n", .{parent.toHex()});
        try writer.print("author {s} {} {s}\n", .{ author, author_time, author_tz });
        try writer.print("committer {s} {} {s}\n", .{ author, author_time, author_tz });
        try writer.print("\n{s}", .{message});

        return try self.store.write(self.allocator, .commit, buf.items);
    }

    /// Finish rebase - update branch ref
    fn finish(self: *Self, state: *RebaseState) !void {
        // Update the original branch to point to new HEAD
        try self.refs.update(state.head_name, state.head);

        // Restore symbolic HEAD
        try self.refs.updateSymbolicRef("HEAD", state.head_name);

        // Clean up rebase directory
        const rebase_path = try std.fs.path.join(self.allocator, &.{ self.git_dir, REBASE_DIR });
        defer self.allocator.free(rebase_path);

        try std.fs.deleteTreeAbsolute(rebase_path);
    }

    /// Save current state to disk
    fn saveState(self: *Self, state: *const RebaseState) !void {
        const state_path = try std.fs.path.join(self.allocator, &.{ self.git_dir, REBASE_DIR, STATE_FILE });
        defer self.allocator.free(state_path);

        const state_file = try std.fs.createFileAbsolute(state_path, .{});
        defer state_file.close();
        try state.serialize(state_file.writer());
    }
};

test "rebase state serialization" {
    const allocator = std.testing.allocator;

    const state = RebaseState{
        .head_name = "refs/heads/main",
        .orig_head = hash_mod.Sha1.fromHex("abc1234567890123456789012345678901234567".*) catch unreachable,
        .onto = hash_mod.Sha1.fromHex("def1234567890123456789012345678901234567".*) catch unreachable,
        .head = hash_mod.Sha1.fromHex("123456789012345678901234567890abcdef0123".*) catch unreachable,
        .current = 3,
        .total = 10,
        .stopped = true,
        .squash_msg = "",
        .allocator = allocator,
    };

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try state.serialize(fbs.writer());

    var deserialized = try RebaseState.deserialize(allocator, fbs.getWritten());
    defer deserialized.deinit();

    try std.testing.expectEqualStrings("refs/heads/main", deserialized.head_name);
    try std.testing.expectEqual(@as(usize, 3), deserialized.current);
    try std.testing.expectEqual(@as(usize, 10), deserialized.total);
    try std.testing.expect(deserialized.stopped);
}
