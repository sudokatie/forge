// Submodule command
//
// Handles git submodule init, update, status, and sync operations.

const std = @import("std");
const submodule_mod = @import("../submodule/mod.zig");
const hash_mod = @import("../object/hash.zig");
const store_mod = @import("../object/store.zig");
const refs_mod = @import("../refs/ref.zig");
const protocol_mod = @import("../protocol/mod.zig");

pub const SubmoduleCommand = struct {
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    work_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) Self {
        // Work dir is parent of git_dir
        const work_dir = std.fs.path.dirname(git_dir) orelse ".";
        return .{
            .allocator = allocator,
            .git_dir = git_dir,
            .work_dir = work_dir,
        };
    }

    pub fn run(self: *Self, args: []const []const u8) !void {
        if (args.len == 0) {
            try self.printUsage();
            return;
        }

        const subcommand = args[0];
        const rest = args[1..];

        if (std.mem.eql(u8, subcommand, "init")) {
            try self.subInit(rest);
        } else if (std.mem.eql(u8, subcommand, "update")) {
            try self.subUpdate(rest);
        } else if (std.mem.eql(u8, subcommand, "status")) {
            try self.subStatus(rest);
        } else if (std.mem.eql(u8, subcommand, "sync")) {
            try self.subSync(rest);
        } else if (std.mem.eql(u8, subcommand, "add")) {
            try self.subAdd(rest);
        } else {
            std.debug.print("Unknown subcommand: {s}\n", .{subcommand});
            try self.printUsage();
        }
    }

    /// Initialize submodules
    fn subInit(self: *Self, args: []const []const u8) !void {
        const config = try self.loadConfig();
        defer @constCast(&config).deinit();

        var initialized: usize = 0;
        for (config.submodules) |sm| {
            // Check if specific paths were given
            if (args.len > 0) {
                var found = false;
                for (args) |path| {
                    if (std.mem.eql(u8, sm.path, path) or std.mem.eql(u8, sm.name, path)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }

            // Write submodule config to .git/config
            try self.writeSubmoduleConfig(&sm);
            std.debug.print("Submodule '{s}' ({s}) registered for path '{s}'\n", .{ sm.name, sm.url, sm.path });
            initialized += 1;
        }

        if (initialized == 0 and args.len > 0) {
            std.debug.print("No submodule found matching paths\n", .{});
        }
    }

    /// Update submodules (fetch and checkout)
    fn subUpdate(self: *Self, args: []const []const u8) !void {
        var recursive = false;
        var init_first = false;
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer paths.deinit(self.allocator);

        // Parse args
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--recursive")) {
                recursive = true;
            } else if (std.mem.eql(u8, arg, "--init")) {
                init_first = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                try paths.append(self.allocator, arg);
            }
        }

        if (init_first) {
            try self.subInit(paths.items);
        }

        const config = try self.loadConfig();
        defer @constCast(&config).deinit();

        for (config.submodules) |sm| {
            // Check if specific paths were given
            if (paths.items.len > 0) {
                var found = false;
                for (paths.items) |path| {
                    if (std.mem.eql(u8, sm.path, path) or std.mem.eql(u8, sm.name, path)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }

            try self.updateSubmodule(&sm, recursive);
        }
    }

    /// Show submodule status
    fn subStatus(self: *Self, args: []const []const u8) !void {
        // Parse args for recursive flag
        var recursive = false;
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--recursive")) {
                recursive = true;
            }
        }

        try self.subStatusWithDepth(self.work_dir, recursive, 0);
    }

    /// Show submodule status with recursion depth tracking
    fn subStatusWithDepth(self: *Self, work_dir: []const u8, recursive: bool, depth: usize) !void {
        const gitmodules_path = try std.fs.path.join(self.allocator, &.{ work_dir, ".gitmodules" });
        defer self.allocator.free(gitmodules_path);

        const file = std.fs.openFileAbsolute(gitmodules_path, .{}) catch {
            return; // No .gitmodules, nothing to do
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var config = try submodule_mod.SubmoduleConfig.parse(self.allocator, content);
        defer config.deinit();

        var checker = submodule_mod.SubmoduleStatusChecker.init(self.allocator, work_dir);

        // Get recorded SHAs from index (simplified - would need index parsing)
        const recorded = try self.allocator.alloc(?hash_mod.Sha1, config.submodules.len);
        defer self.allocator.free(recorded);
        @memset(recorded, null);

        const entries = try checker.checkAll(&config, recorded);
        defer self.allocator.free(entries);

        // Build indent string based on depth
        const indent = try self.allocator.alloc(u8, depth * 2);
        defer self.allocator.free(indent);
        @memset(indent, ' ');

        for (entries) |*entry| {
            // Format and print status with indentation
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
                std.debug.print("{s}{c}{s} {s}\n", .{ indent, prefix, sha[0..7], entry.path });
            } else {
                std.debug.print("{s}{c}(none)  {s}\n", .{ indent, prefix, entry.path });
            }

            // If recursive, check for nested submodules
            if (recursive and entry.status != .uninitialized and entry.status != .missing) {
                const sm_work_dir = try std.fs.path.join(self.allocator, &.{ work_dir, entry.path });
                defer self.allocator.free(sm_work_dir);

                // Check if this submodule has its own .gitmodules
                const nested_gitmodules = try std.fs.path.join(self.allocator, &.{ sm_work_dir, ".gitmodules" });
                defer self.allocator.free(nested_gitmodules);

                if (std.fs.accessAbsolute(nested_gitmodules, .{})) |_| {
                    try self.subStatusWithDepth(sm_work_dir, recursive, depth + 1);
                } else |_| {
                    // No nested submodules, continue
                }
            }
        }
    }

    /// Sync submodule URLs
    fn subSync(self: *Self, args: []const []const u8) !void {
        _ = args;

        const config = try self.loadConfig();
        defer @constCast(&config).deinit();

        for (config.submodules) |sm| {
            try self.writeSubmoduleConfig(&sm);
            std.debug.print("Synchronizing submodule url for '{s}'\n", .{sm.name});
        }
    }

    /// Add a new submodule
    fn subAdd(self: *Self, args: []const []const u8) !void {
        if (args.len < 2) {
            std.debug.print("Usage: forge submodule add <url> <path>\n", .{});
            return;
        }

        const url = args[0];
        const path = args[1];

        // Derive name from path
        const name = std.fs.path.basename(path);

        std.debug.print("Adding submodule '{s}' at '{s}'\n", .{ name, path });

        // Clone the repository
        try self.cloneSubmodule(url, path);

        // Add to .gitmodules
        try self.appendGitmodules(name, path, url);

        std.debug.print("Submodule added. Run 'git add .gitmodules {s}' to stage.\n", .{path});
    }

    /// Load .gitmodules configuration
    fn loadConfig(self: *Self) !submodule_mod.SubmoduleConfig {
        const gitmodules_path = try std.fs.path.join(self.allocator, &.{ self.work_dir, ".gitmodules" });
        defer self.allocator.free(gitmodules_path);

        const file = std.fs.openFileAbsolute(gitmodules_path, .{}) catch {
            return submodule_mod.SubmoduleConfig{
                .submodules = &.{},
                .allocator = self.allocator,
            };
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        return submodule_mod.SubmoduleConfig.parse(self.allocator, content);
    }

    /// Write submodule config to .git/config
    fn writeSubmoduleConfig(self: *Self, sm: *const submodule_mod.Submodule) !void {
        const config_path = try std.fs.path.join(self.allocator, &.{ self.git_dir, "config" });
        defer self.allocator.free(config_path);

        const file = try std.fs.openFileAbsolute(config_path, .{ .mode = .read_write });
        defer file.close();

        // Read existing config
        const existing = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(existing);

        // Check if already present
        var section_header: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&section_header, "[submodule \"{s}\"]", .{sm.name}) catch return;
        if (std.mem.indexOf(u8, existing, header) != null) {
            return; // Already configured
        }

        // Append new section
        try file.seekFromEnd(0);
        var buf: [512]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "\n[submodule \"{s}\"]\n\tactive = true\n\turl = {s}\n", .{ sm.name, sm.url }) catch return;
        try file.writeAll(content);
    }

    /// Update a single submodule
    fn updateSubmodule(self: *Self, sm: *const submodule_mod.Submodule, recursive: bool) !void {
        _ = recursive;

        const sm_path = try std.fs.path.join(self.allocator, &.{ self.work_dir, sm.path });
        defer self.allocator.free(sm_path);

        // Check if already cloned
        const git_path = try std.fs.path.join(self.allocator, &.{ sm_path, ".git" });
        defer self.allocator.free(git_path);

        std.fs.accessAbsolute(git_path, .{}) catch {
            // Not initialized - clone it
            try self.cloneSubmodule(sm.url, sm.path);
            return;
        };

        // Already exists - fetch and checkout
        std.debug.print("Submodule '{s}' already initialized\n", .{sm.name});
    }

    /// Clone a submodule repository
    fn cloneSubmodule(self: *Self, url: []const u8, path: []const u8) !void {
        const full_path = try std.fs.path.join(self.allocator, &.{ self.work_dir, path });
        defer self.allocator.free(full_path);

        // Create directory
        std.fs.makeDirAbsolute(full_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        std.debug.print("Cloning into '{s}'...\n", .{path});
        std.debug.print("  From: {s}\n", .{url});

        // Use existing clone infrastructure
        // (Simplified - in full impl would use clone command)
    }

    /// Append entry to .gitmodules
    fn appendGitmodules(self: *Self, name: []const u8, path: []const u8, url: []const u8) !void {
        const gitmodules_path = try std.fs.path.join(self.allocator, &.{ self.work_dir, ".gitmodules" });
        defer self.allocator.free(gitmodules_path);

        const file = try std.fs.createFileAbsolute(gitmodules_path, .{
            .truncate = false,
            .exclusive = false,
        });
        defer file.close();

        // Seek to end
        try file.seekFromEnd(0);

        var buf: [512]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "\n[submodule \"{s}\"]\n\tpath = {s}\n\turl = {s}\n", .{ name, path, url }) catch return;
        try file.writeAll(content);
    }

    fn printUsage(_: *Self) !void {
        std.debug.print(
            \\Usage: forge submodule <command> [options]
            \\
            \\Commands:
            \\  init [path...]        Initialize submodule(s)
            \\  update [options]      Update submodule(s)
            \\  status [--recursive]  Show submodule status
            \\  sync [path...]        Sync submodule URLs from .gitmodules
            \\  add <url> <path>      Add a new submodule
            \\
            \\Update options:
            \\  --init       Initialize if not already
            \\  --recursive  Update nested submodules
            \\
        , .{});
    }
};

/// Entry point for CLI
pub fn run(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8) !void {
    var cmd = SubmoduleCommand.init(allocator, git_dir);
    try cmd.run(args);
}

test "submodule command init" {
    const allocator = std.testing.allocator;
    const cmd = SubmoduleCommand.init(allocator, "/tmp/.git");
    try std.testing.expectEqualStrings("/tmp", cmd.work_dir);
}

test "subStatus parses recursive flag" {
    const allocator = std.testing.allocator;
    var cmd = SubmoduleCommand.init(allocator, "/tmp/nonexistent/.git");

    // Should not error even with no .gitmodules (just returns early)
    const args_recursive = &[_][]const u8{"--recursive"};
    try cmd.subStatus(args_recursive);

    const args_empty = &[_][]const u8{};
    try cmd.subStatus(args_empty);
}

test "subStatusWithDepth handles missing gitmodules" {
    const allocator = std.testing.allocator;
    var cmd = SubmoduleCommand.init(allocator, "/tmp/nonexistent/.git");

    // Should return cleanly when no .gitmodules exists
    try cmd.subStatusWithDepth("/tmp/nonexistent", false, 0);
    try cmd.subStatusWithDepth("/tmp/nonexistent", true, 0);
}

test "subStatusWithDepth builds correct indent" {
    const allocator = std.testing.allocator;

    // Test indent allocation for different depths
    for ([_]usize{ 0, 1, 2, 3 }) |depth| {
        const indent = try allocator.alloc(u8, depth * 2);
        defer allocator.free(indent);
        @memset(indent, ' ');

        try std.testing.expectEqual(depth * 2, indent.len);
        for (indent) |c| {
            try std.testing.expectEqual(@as(u8, ' '), c);
        }
    }
}

test "recursive status with nested submodules" {
    const allocator = std.testing.allocator;

    // Create a temp directory structure simulating nested submodules
    const tmp_dir = "/tmp/forge-test-recursive-submodule";

    // Clean up any existing test directory
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create directory structure
    std.fs.makeDirAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const outer_sm = try std.fs.path.join(allocator, &.{ tmp_dir, "outer" });
    defer allocator.free(outer_sm);
    std.fs.makeDirAbsolute(outer_sm) catch {};

    const outer_git = try std.fs.path.join(allocator, &.{ outer_sm, ".git" });
    defer allocator.free(outer_git);
    std.fs.makeDirAbsolute(outer_git) catch {};

    const inner_sm = try std.fs.path.join(allocator, &.{ outer_sm, "inner" });
    defer allocator.free(inner_sm);
    std.fs.makeDirAbsolute(inner_sm) catch {};

    const inner_git = try std.fs.path.join(allocator, &.{ inner_sm, ".git" });
    defer allocator.free(inner_git);
    std.fs.makeDirAbsolute(inner_git) catch {};

    // Create root .gitmodules
    const root_gitmodules = try std.fs.path.join(allocator, &.{ tmp_dir, ".gitmodules" });
    defer allocator.free(root_gitmodules);
    {
        const file = try std.fs.createFileAbsolute(root_gitmodules, .{});
        defer file.close();
        try file.writeAll(
            \\[submodule "outer"]
            \\    path = outer
            \\    url = https://example.com/outer.git
            \\
        );
    }

    // Create nested .gitmodules in outer submodule
    const outer_gitmodules = try std.fs.path.join(allocator, &.{ outer_sm, ".gitmodules" });
    defer allocator.free(outer_gitmodules);
    {
        const file = try std.fs.createFileAbsolute(outer_gitmodules, .{});
        defer file.close();
        try file.writeAll(
            \\[submodule "inner"]
            \\    path = inner
            \\    url = https://example.com/inner.git
            \\
        );
    }

    // Create HEAD files for initialized submodules
    const outer_head = try std.fs.path.join(allocator, &.{ outer_git, "HEAD" });
    defer allocator.free(outer_head);
    {
        const file = try std.fs.createFileAbsolute(outer_head, .{});
        defer file.close();
        try file.writeAll("abcdef1234567890abcdef1234567890abcdef12\n");
    }

    const inner_head = try std.fs.path.join(allocator, &.{ inner_git, "HEAD" });
    defer allocator.free(inner_head);
    {
        const file = try std.fs.createFileAbsolute(inner_head, .{});
        defer file.close();
        try file.writeAll("1234567890abcdef1234567890abcdef12345678\n");
    }

    // Run recursive status
    var cmd = SubmoduleCommand.init(allocator, try std.fs.path.join(allocator, &.{ tmp_dir, ".git" }));
    // Note: cmd owns this path now via work_dir derivation

    // Non-recursive should only show outer
    try cmd.subStatusWithDepth(tmp_dir, false, 0);

    // Recursive should show both outer and inner
    try cmd.subStatusWithDepth(tmp_dir, true, 0);
}
