// Forge - Git implementation in Zig
//
// CLI entry point

const std = @import("std");
const lib = @import("lib.zig");
const cmd = @import("cmd/mod.zig");
const posix = std.posix;

const version = "0.1.0";

fn stdout() std.fs.File {
    return .{ .handle = posix.STDOUT_FILENO };
}

fn stderr() std.fs.File {
    return .{ .handle = posix.STDERR_FILENO };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    const cmd_args = args[2..];

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "forge {s}\n", .{version}) catch unreachable;
        try stdout().writeAll(msg);
        return;
    }

    // Route to command handler
    try runCommand(allocator, command, cmd_args);
}

fn runCommand(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) !void {
    if (std.mem.eql(u8, command, "init")) {
        try cmd.init.run(allocator, args);
    } else if (std.mem.eql(u8, command, "add")) {
        try cmd.add.run(allocator, args);
    } else if (std.mem.eql(u8, command, "commit")) {
        try cmd.commit.run(allocator, args);
    } else if (std.mem.eql(u8, command, "log")) {
        try cmd.log.run(allocator, args);
    } else if (std.mem.eql(u8, command, "status")) {
        try cmd.status.run(allocator, args);
    } else if (std.mem.eql(u8, command, "diff")) {
        try cmd.diff.run(allocator, args);
    } else if (std.mem.eql(u8, command, "branch")) {
        try cmd.branch.run(allocator, args);
    } else if (std.mem.eql(u8, command, "checkout")) {
        try cmd.checkout.run(allocator, args);
    } else if (std.mem.eql(u8, command, "clone")) {
        try cmd.clone.run(allocator, args);
    } else if (std.mem.eql(u8, command, "fetch")) {
        try cmd.fetch.run(allocator, args);
    } else if (std.mem.eql(u8, command, "push")) {
        try cmd.push.run(allocator, args);
    } else if (std.mem.eql(u8, command, "tag")) {
        try cmd.tag.run(allocator, args);
    } else if (std.mem.eql(u8, command, "hash-object")) {
        try cmd.hash_object.run(allocator, args);
    } else if (std.mem.eql(u8, command, "cat-file")) {
        try cmd.cat_file.run(allocator, args);
    } else if (std.mem.eql(u8, command, "ls-tree")) {
        try cmd.ls_tree.run(allocator, args);
    } else if (std.mem.eql(u8, command, "ls-files")) {
        try cmd.ls_files.run(allocator, args);
    } else if (std.mem.eql(u8, command, "write-tree")) {
        try cmd.write_tree.run(allocator, args);
    } else if (std.mem.eql(u8, command, "commit-tree")) {
        try cmd.commit_tree.run(allocator, args);
    } else if (std.mem.eql(u8, command, "rev-parse")) {
        try cmd.rev_parse.run(allocator, args);
    } else if (std.mem.eql(u8, command, "update-ref")) {
        try cmd.update_ref.run(allocator, args);
    } else if (std.mem.eql(u8, command, "update-index")) {
        try cmd.update_index.run(allocator, args);
    } else if (std.mem.eql(u8, command, "submodule")) {
        try cmd.submodule.run(allocator, ".git", args);
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "forge: '{s}' is not a forge command. See 'forge --help'.\n", .{command}) catch {
            try stderr().writeAll("forge: unknown command\n");
            std.process.exit(1);
        };
        try stderr().writeAll(msg);
        std.process.exit(1);
    }
}

fn printUsage() void {
    const usage =
        \\usage: forge <command> [<args>]
        \\
        \\These are common Forge commands:
        \\
        \\start a working area:
        \\   init        Create an empty repository
        \\   clone       Clone a repository
        \\
        \\work on the current change:
        \\   add         Add file contents to the index
        \\   status      Show the working tree status
        \\   diff        Show changes between commits
        \\
        \\examine the history:
        \\   log         Show commit logs
        \\
        \\grow, mark and tweak your common history:
        \\   branch      List, create, or delete branches
        \\   commit      Record changes to the repository
        \\   checkout    Switch branches or restore files
        \\   tag         Create, list, or delete tags
        \\
        \\collaborate:
        \\   fetch       Download objects and refs from remote
        \\   push        Update remote refs along with objects
        \\
        \\plumbing:
        \\   hash-object Compute object ID
        \\   cat-file    Show object contents
        \\
        \\'forge --help' or 'forge -h' to see this message
        \\'forge --version' or 'forge -v' to see version
        \\
    ;
    stdout().writeAll(usage) catch {};
}
