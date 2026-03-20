// forge log - show commit history

const std = @import("std");
const object = @import("../object/mod.zig");
const refs = @import("../refs/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    // Parse flags
    var oneline = false;
    var limit: ?usize = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--oneline")) {
            oneline = true;
        } else if (std.mem.startsWith(u8, arg, "-n")) {
            const n_str = arg[2..];
            limit = std.fmt.parseInt(usize, n_str, 10) catch null;
        }
    }

    // Get HEAD
    var ref_store = refs.RefStore.init(allocator, ".git");
    const head = ref_store.readHead() catch |err| {
        if (err == error.HeadNotFound) {
            try stderr.writeAll("fatal: your current branch does not have any commits yet\n");
            return;
        }
        return err;
    };

    // Resolve to SHA
    var current_sha: object.Sha1 = switch (head) {
        .direct => |sha| sha,
        .symbolic => |sym| ref_store.resolve(sym) catch {
            try stderr.writeAll("fatal: your current branch does not have any commits yet\n");
            return;
        },
    };

    var store = object.ObjectStore.init(allocator, ".git");
    var count: usize = 0;

    // Walk commit history
    while (true) {
        if (limit) |l| {
            if (count >= l) break;
        }

        const obj = store.read(current_sha) catch break;
        if (obj != .commit) break;

        const commit = obj.commit;
        defer {
            var c = commit;
            c.deinit();
        }

        if (oneline) {
            const hex = object.hash.toHex(current_sha);
            var buf: [512]u8 = undefined;
            // Get first line of message
            const first_line = std.mem.indexOf(u8, commit.message, "\n") orelse commit.message.len;
            const msg = std.fmt.bufPrint(&buf, "{s} {s}\n", .{ hex[0..7], commit.message[0..first_line] }) catch {
                try stdout.writeAll("...\n");
                break;
            };
            try stdout.writeAll(msg);
        } else {
            const hex = object.hash.toHex(current_sha);
            try stdout.writeAll("commit ");
            try stdout.writeAll(&hex);
            try stdout.writeAll("\n");
            try stdout.writeAll("Author: ");
            try stdout.writeAll(commit.author);
            try stdout.writeAll("\n\n    ");
            try stdout.writeAll(commit.message);
            try stdout.writeAll("\n");
        }

        count += 1;

        // Move to parent
        if (commit.parents.len > 0) {
            current_sha = commit.parents[0];
        } else {
            break;
        }
    }
}

test "log basic" {
    // Would need temp repo with commits
}
