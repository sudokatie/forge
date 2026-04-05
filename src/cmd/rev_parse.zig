// forge rev-parse - resolve refs to SHA-1

const std = @import("std");
const object = @import("../object/mod.zig");
const refs = @import("../refs/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var show_toplevel = false;
    var show_git_dir = false;
    var verify = false;
    var quiet = false;
    var refs_to_resolve: std.ArrayList([]const u8) = .empty;
    defer refs_to_resolve.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--show-toplevel")) {
            show_toplevel = true;
        } else if (std.mem.eql(u8, arg, "--git-dir")) {
            show_git_dir = true;
        } else if (std.mem.eql(u8, arg, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try refs_to_resolve.append(allocator, arg);
        }
    }

    if (show_toplevel) {
        const cwd = std.fs.cwd();
        const abs_path = cwd.realpathAlloc(allocator, ".") catch {
            if (!quiet) try stderr.writeAll("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer allocator.free(abs_path);
        try stdout.writeAll(abs_path);
        try stdout.writeAll("\n");
        return;
    }

    if (show_git_dir) {
        const cwd = std.fs.cwd();
        cwd.access(".git", .{}) catch {
            if (!quiet) try stderr.writeAll("fatal: not a git repository\n");
            std.process.exit(128);
        };
        try stdout.writeAll(".git\n");
        return;
    }

    if (refs_to_resolve.items.len == 0) {
        try stderr.writeAll("usage: forge rev-parse [--show-toplevel] [--git-dir] [--verify] <ref>...\n");
        return;
    }

    var ref_store = refs.RefStore.init(allocator, ".git");
    var store = object.ObjectStore.init(allocator, ".git");

    for (refs_to_resolve.items) |ref| {
        const sha = resolveRef(allocator, ref, &ref_store, &store) catch {
            if (verify) {
                if (!quiet) try stderr.writeAll("fatal: Needed a single revision\n");
                std.process.exit(128);
            }
            if (!quiet) {
                try stdout.writeAll(ref);
                try stdout.writeAll("\n");
            }
            continue;
        };

        const hex = object.hash.toHex(sha);
        try stdout.writeAll(&hex);
        try stdout.writeAll("\n");
    }
}

fn resolveRef(
    allocator: std.mem.Allocator,
    ref: []const u8,
    ref_store: *refs.RefStore,
    store: *object.ObjectStore,
) !object.Sha1 {
    // Direct SHA
    if (ref.len == 40) {
        if (object.hash.fromHex(ref[0..40])) |sha| {
            if (store.exists(sha)) return sha;
        } else |_| {}
    }

    // HEAD
    if (std.mem.eql(u8, ref, "HEAD")) {
        const head = try ref_store.readHead();
        return switch (head) {
            .direct => |s| s,
            .symbolic => |sym| blk: {
                defer allocator.free(sym);
                break :blk try ref_store.resolve(sym);
            },
        };
    }

    // HEAD^ (parent)
    if (std.mem.eql(u8, ref, "HEAD^") or std.mem.eql(u8, ref, "HEAD~1")) {
        const head_sha = try resolveRef(allocator, "HEAD", ref_store, store);
        const obj = try store.read(head_sha);
        if (obj != .commit) return error.NotACommit;
        if (obj.commit.parents.len == 0) return error.NoParent;
        return obj.commit.parents[0];
    }

    // Branch name
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
    defer allocator.free(branch_ref);

    if (ref_store.resolve(branch_ref)) |sha| {
        return sha;
    } else |_| {}

    // Tag name
    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{ref});
    defer allocator.free(tag_ref);

    if (ref_store.resolve(tag_ref)) |sha| {
        return sha;
    } else |_| {}

    return error.RefNotFound;
}

test "rev-parse basic" {
    // Would need temp repo
}
