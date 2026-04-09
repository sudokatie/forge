// Submodule status tracking
//
// Tracks the state of submodules relative to their recorded commits.

const std = @import("std");
const hash_mod = @import("../object/hash.zig");
const config_mod = @import("config.zig");

/// Status of a single submodule
pub const SubmoduleStatus = enum {
    /// Not initialized (no .git directory)
    uninitialized,
    /// Initialized but not checked out
    initialized,
    /// Checked out at recorded commit
    clean,
    /// Checked out but HEAD differs from recorded commit
    modified,
    /// Has uncommitted changes in working tree
    dirty,
    /// Missing from filesystem
    missing,
    /// Configuration missing from .gitmodules
    unconfigured,
};

/// Status entry for a submodule
pub const SubmoduleStatusEntry = struct {
    /// Submodule name
    name: []const u8,
    /// Submodule path
    path: []const u8,
    /// Status
    status: SubmoduleStatus,
    /// Commit recorded in parent index
    recorded_sha: ?hash_mod.Sha1,
    /// Current HEAD in submodule (if initialized)
    current_sha: ?hash_mod.Sha1,
    /// Description of status
    desc: []const u8,

    /// Check if submodule needs update
    pub fn needsUpdate(self: SubmoduleStatusEntry) bool {
        return switch (self.status) {
            .uninitialized, .modified, .missing => true,
            .initialized, .clean, .dirty, .unconfigured => false,
        };
    }

    /// Check if submodule has local changes
    pub fn hasLocalChanges(self: SubmoduleStatusEntry) bool {
        return self.status == .dirty;
    }
};

/// Submodule status checker
pub const SubmoduleStatusChecker = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) Self {
        return .{
            .allocator = allocator,
            .root_path = root_path,
        };
    }

    /// Check status of all configured submodules
    pub fn checkAll(
        self: *Self,
        config: *const config_mod.SubmoduleConfig,
        recorded_shas: []const ?hash_mod.Sha1,
    ) ![]SubmoduleStatusEntry {
        var entries: std.ArrayListUnmanaged(SubmoduleStatusEntry) = .empty;
        errdefer entries.deinit(self.allocator);

        for (config.submodules, 0..) |sm, i| {
            const recorded = if (i < recorded_shas.len) recorded_shas[i] else null;
            const entry = try self.checkOne(&sm, recorded);
            try entries.append(self.allocator, entry);
        }

        return try entries.toOwnedSlice(self.allocator);
    }

    /// Check status of a single submodule
    pub fn checkOne(
        self: *Self,
        sm: *const config_mod.Submodule,
        recorded_sha: ?hash_mod.Sha1,
    ) !SubmoduleStatusEntry {
        const sm_path = try std.fs.path.join(self.allocator, &.{ self.root_path, sm.path });
        defer self.allocator.free(sm_path);

        // Check if directory exists
        var sm_dir = std.fs.openDirAbsolute(sm_path, .{}) catch {
            return SubmoduleStatusEntry{
                .name = sm.name,
                .path = sm.path,
                .status = .missing,
                .recorded_sha = recorded_sha,
                .current_sha = null,
                .desc = "submodule path missing",
            };
        };
        defer sm_dir.close();

        // Check if .git exists (initialized)
        const git_path = try std.fs.path.join(self.allocator, &.{ sm_path, ".git" });
        defer self.allocator.free(git_path);

        std.fs.accessAbsolute(git_path, .{}) catch {
            return SubmoduleStatusEntry{
                .name = sm.name,
                .path = sm.path,
                .status = .uninitialized,
                .recorded_sha = recorded_sha,
                .current_sha = null,
                .desc = "submodule not initialized",
            };
        };

        // Read current HEAD
        const head_path = try std.fs.path.join(self.allocator, &.{ sm_path, ".git", "HEAD" });
        defer self.allocator.free(head_path);

        const current_sha = self.readHead(head_path) catch null;

        // Compare with recorded
        if (recorded_sha) |rec| {
            if (current_sha) |cur| {
                if (std.mem.eql(u8, &rec, &cur)) {
                    return SubmoduleStatusEntry{
                        .name = sm.name,
                        .path = sm.path,
                        .status = .clean,
                        .recorded_sha = recorded_sha,
                        .current_sha = current_sha,
                        .desc = "submodule up to date",
                    };
                } else {
                    return SubmoduleStatusEntry{
                        .name = sm.name,
                        .path = sm.path,
                        .status = .modified,
                        .recorded_sha = recorded_sha,
                        .current_sha = current_sha,
                        .desc = "submodule has different commit checked out",
                    };
                }
            }
        }

        return SubmoduleStatusEntry{
            .name = sm.name,
            .path = sm.path,
            .status = .initialized,
            .recorded_sha = recorded_sha,
            .current_sha = current_sha,
            .desc = "submodule initialized",
        };
    }

    /// Read HEAD commit from a git directory
    fn readHead(self: *Self, head_path: []const u8) !hash_mod.Sha1 {
        _ = self;
        const file = try std.fs.openFileAbsolute(head_path, .{});
        defer file.close();

        var buf: [256]u8 = undefined;
        const len = try file.readAll(&buf);
        const content = std.mem.trim(u8, buf[0..len], " \t\r\n");

        // Direct SHA reference
        if (content.len >= 40 and !std.mem.startsWith(u8, content, "ref:")) {
            return hash_mod.fromHex(content[0..40]);
        }

        // Symbolic ref - would need to resolve
        return error.SymbolicRef;
    }
};

/// Format status for display
pub fn formatStatus(entry: *const SubmoduleStatusEntry, writer: anytype) !void {
    const prefix: u8 = switch (entry.status) {
        .uninitialized => '-',
        .initialized => ' ',
        .clean => ' ',
        .modified => '+',
        .dirty => '*',
        .missing => '!',
        .unconfigured => '?',
    };

    if (entry.current_sha) |sha| {
        const hex = hash_mod.toHex(sha);
        try writer.print("{c}{s} {s}", .{ prefix, hex[0..7], entry.path });
    } else {
        try writer.print("{c}(none)  {s}", .{ prefix, entry.path });
    }

    if (entry.status == .modified) {
        if (entry.recorded_sha) |rec| {
            const rec_hex = hash_mod.toHex(rec);
            try writer.print(" (recorded: {s})", .{rec_hex[0..7]});
        }
    }

    try writer.writeByte('\n');
}

// Tests

test "status entry needs update" {
    const entry_uninit = SubmoduleStatusEntry{
        .name = "test",
        .path = "test",
        .status = .uninitialized,
        .recorded_sha = null,
        .current_sha = null,
        .desc = "",
    };
    try std.testing.expect(entry_uninit.needsUpdate());

    const entry_clean = SubmoduleStatusEntry{
        .name = "test",
        .path = "test",
        .status = .clean,
        .recorded_sha = null,
        .current_sha = null,
        .desc = "",
    };
    try std.testing.expect(!entry_clean.needsUpdate());

    const entry_modified = SubmoduleStatusEntry{
        .name = "test",
        .path = "test",
        .status = .modified,
        .recorded_sha = null,
        .current_sha = null,
        .desc = "",
    };
    try std.testing.expect(entry_modified.needsUpdate());
}

test "status entry has local changes" {
    const entry_dirty = SubmoduleStatusEntry{
        .name = "test",
        .path = "test",
        .status = .dirty,
        .recorded_sha = null,
        .current_sha = null,
        .desc = "",
    };
    try std.testing.expect(entry_dirty.hasLocalChanges());

    const entry_clean = SubmoduleStatusEntry{
        .name = "test",
        .path = "test",
        .status = .clean,
        .recorded_sha = null,
        .current_sha = null,
        .desc = "",
    };
    try std.testing.expect(!entry_clean.hasLocalChanges());
}

test "format status output" {
    const sha = hash_mod.fromHex("abc1234567890123456789012345678901234567") catch unreachable;
    const entry = SubmoduleStatusEntry{
        .name = "mylib",
        .path = "vendor/mylib",
        .status = .clean,
        .recorded_sha = sha,
        .current_sha = sha,
        .desc = "up to date",
    };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try formatStatus(&entry, fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "vendor/mylib") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "abc1234") != null);
}
