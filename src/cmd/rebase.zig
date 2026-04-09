// Rebase Command
// Interactive rebase with support for pick, reword, edit, squash, fixup, drop

const std = @import("std");
const rebase_mod = @import("../rebase/mod.zig");
const hash_mod = @import("../object/hash.zig");
const store_mod = @import("../object/store.zig");
const commit_mod = @import("../object/commit.zig");
const refs_mod = @import("../refs/ref.zig");

pub const RebaseCommand = struct {
    allocator: std.mem.Allocator,
    git_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .git_dir = git_dir,
        };
    }

    /// Run the rebase command with given arguments
    pub fn run(self: *Self, args: []const []const u8) !void {
        if (args.len == 0) {
            try self.printUsage();
            return;
        }

        // Parse flags
        var interactive = false;
        var do_continue = false;
        var do_abort = false;
        var do_skip = false;
        var onto: ?[]const u8 = null;
        var upstream: ?[]const u8 = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
                interactive = true;
            } else if (std.mem.eql(u8, arg, "--continue")) {
                do_continue = true;
            } else if (std.mem.eql(u8, arg, "--abort")) {
                do_abort = true;
            } else if (std.mem.eql(u8, arg, "--skip")) {
                do_skip = true;
            } else if (std.mem.eql(u8, arg, "--onto")) {
                i += 1;
                if (i < args.len) {
                    onto = args[i];
                }
            } else if (arg[0] != '-') {
                if (upstream == null) {
                    upstream = arg;
                }
            }
        }

        // Open object store and refs
        var store = try store_mod.ObjectStore.init(self.allocator, self.git_dir);
        defer store.deinit();

        var refs = try refs_mod.RefStore.init(self.allocator, self.git_dir);
        defer refs.deinit();

        var engine = rebase_mod.RebaseEngine.init(
            self.allocator,
            self.git_dir,
            &store,
            &refs,
        );

        // Handle --continue, --abort, --skip
        if (do_continue) {
            try engine.continueRebase();
            try self.printStatus(&engine);
            return;
        }

        if (do_abort) {
            try engine.abort();
            std.debug.print("Rebase aborted\n", .{});
            return;
        }

        if (do_skip) {
            try engine.skip();
            try self.printStatus(&engine);
            return;
        }

        // Start new rebase
        if (!interactive) {
            std.debug.print("Non-interactive rebase not yet supported. Use -i.\n", .{});
            return;
        }

        const target = upstream orelse {
            std.debug.print("Error: must specify upstream commit\n", .{});
            return;
        };

        try self.startInteractiveRebase(&engine, &store, &refs, target, onto);
    }

    /// Start an interactive rebase
    fn startInteractiveRebase(
        self: *Self,
        engine: *rebase_mod.RebaseEngine,
        store: *store_mod.ObjectStore,
        refs: *refs_mod.RefStore,
        upstream: []const u8,
        onto: ?[]const u8,
    ) !void {
        // Resolve upstream
        const upstream_hash = try refs.resolve(upstream);

        // Resolve onto (defaults to upstream)
        const onto_hash = if (onto) |o| try refs.resolve(o) else upstream_hash;

        // Get current HEAD
        const head_hash = try refs.readHead();
        const head_name = try refs.readHeadRef();

        // Collect commits to rebase (between upstream and HEAD)
        var commits = std.ArrayList(hash_mod.Sha1).init(self.allocator);
        defer commits.deinit();

        var subjects = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (subjects.items) |s| self.allocator.free(s);
            subjects.deinit();
        }

        try self.collectCommits(store, head_hash, upstream_hash, &commits, &subjects);

        if (commits.items.len == 0) {
            std.debug.print("Nothing to rebase\n", .{});
            return;
        }

        std.debug.print("Rebasing {} commits onto {s}\n", .{
            commits.items.len,
            onto_hash.toHex()[0..7],
        });

        // Start rebase
        try engine.start(
            head_name,
            head_hash,
            onto_hash,
            commits.items,
            subjects.items,
        );

        // Print todo file location
        std.debug.print("\nEdit the todo file, then run:\n", .{});
        std.debug.print("  forge rebase --continue\n", .{});
        std.debug.print("\nOr abort with:\n", .{});
        std.debug.print("  forge rebase --abort\n", .{});
    }

    /// Collect commits between HEAD and upstream
    fn collectCommits(
        self: *Self,
        store: *store_mod.ObjectStore,
        from: hash_mod.Sha1,
        to: hash_mod.Sha1,
        commits: *std.ArrayList(hash_mod.Sha1),
        subjects: *std.ArrayList([]const u8),
    ) !void {
        var current = from;

        // Walk back from HEAD to upstream
        while (!std.mem.eql(u8, &current.bytes, &to.bytes)) {
            const data = store.read(self.allocator, current) catch break;
            defer self.allocator.free(data);

            const commit = try commit_mod.parse(self.allocator, data);
            defer @constCast(&commit).deinit();

            try commits.append(current);

            // Extract first line of message as subject
            var lines = std.mem.splitScalar(u8, commit.message, '\n');
            const subject = lines.next() orelse "";
            try subjects.append(try self.allocator.dupe(u8, subject));

            // Move to parent
            if (commit.parents.len == 0) break;
            current = commit.parents[0];
        }
    }

    /// Print current rebase status
    fn printStatus(_: *Self, engine: *rebase_mod.RebaseEngine) !void {
        if (!engine.isInProgress()) {
            std.debug.print("No rebase in progress\n", .{});
            return;
        }

        var state = try engine.loadState();
        defer state.deinit();

        if (state.stopped) {
            std.debug.print("Rebase stopped at {}/{}\n", .{ state.current + 1, state.total });
            std.debug.print("Edit and continue with: forge rebase --continue\n", .{});
        } else {
            std.debug.print("Rebase complete!\n", .{});
        }
    }

    fn printUsage(self: *Self) !void {
        _ = self;
        std.debug.print(
            \\Usage: forge rebase [-i] <upstream> [--onto <newbase>]
            \\       forge rebase --continue
            \\       forge rebase --abort
            \\       forge rebase --skip
            \\
            \\Options:
            \\  -i, --interactive  Interactive rebase (edit commits)
            \\  --onto <commit>    Rebase onto <commit> instead of <upstream>
            \\  --continue         Continue rebase after resolving conflicts
            \\  --abort            Abort rebase and restore original branch
            \\  --skip             Skip current commit and continue
            \\
            \\Commands in interactive mode:
            \\  pick (p)    - use commit
            \\  reword (r)  - use commit but edit message
            \\  edit (e)    - use commit but stop for amending
            \\  squash (s)  - meld into previous commit
            \\  fixup (f)   - like squash but discard message
            \\  drop (d)    - remove commit
            \\  exec (x)    - run shell command
            \\
        , .{});
    }
};

/// Entry point for rebase command
pub fn run(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8) !void {
    var cmd = RebaseCommand.init(allocator, git_dir);
    try cmd.run(args);
}

test "rebase command initialization" {
    const allocator = std.testing.allocator;
    const cmd = RebaseCommand.init(allocator, "/tmp/test/.git");
    _ = cmd;
}
