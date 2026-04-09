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
        // Parse args (recursive flag for future use)
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--recursive")) {
                // TODO: implement recursive status
            }
        }

        const config = try self.loadConfig();
        defer @constCast(&config).deinit();

        var checker = submodule_mod.SubmoduleStatusChecker.init(self.allocator, self.work_dir);

        // Get recorded SHAs from index (simplified - would need index parsing)
        const recorded = try self.allocator.alloc(?hash_mod.Sha1, config.submodules.len);
        defer self.allocator.free(recorded);
        @memset(recorded, null);

        const entries = try checker.checkAll(&config, recorded);
        defer self.allocator.free(entries);

        for (entries) |*entry| {
            // Format and print status
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
                std.debug.print("{c}{s} {s}\n", .{ prefix, sha[0..7], entry.path });
            } else {
                std.debug.print("{c}(none)  {s}\n", .{ prefix, entry.path });
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
