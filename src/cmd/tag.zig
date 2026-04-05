// forge tag - list, create, or delete tags

const std = @import("std");
const object = @import("../object/mod.zig");
const refs = @import("../refs/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var delete_mode = false;
    var annotate = false;
    var message: ?[]const u8 = null;
    var tag_name: ?[]const u8 = null;
    var target_ref: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            delete_mode = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--annotate")) {
            annotate = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            i += 1;
            if (i < args.len) {
                message = args[i];
                annotate = true; // -m implies -a
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (tag_name == null) {
                tag_name = arg;
            } else if (target_ref == null) {
                target_ref = arg;
            }
        }
    }

    var ref_store = refs.RefStore.init(allocator, ".git");
    const cwd = std.fs.cwd();

    // List tags
    if (tag_name == null and !delete_mode) {
        var dir = cwd.openDir(".git/refs/tags", .{ .iterate = true }) catch {
            // No tags yet
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                try stdout.writeAll(entry.name);
                try stdout.writeAll("\n");
            }
        }
        return;
    }

    const name = tag_name.?;

    // Delete tag
    if (delete_mode) {
        const tag_path = try std.fmt.allocPrint(allocator, ".git/refs/tags/{s}", .{name});
        defer allocator.free(tag_path);

        cwd.deleteFile(tag_path) catch |err| {
            if (err == error.FileNotFound) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: tag '{s}' not found.\n", .{name}) catch "error: tag not found\n";
                try stderr.writeAll(msg);
                return;
            }
            return err;
        };

        try stdout.writeAll("Deleted tag '");
        try stdout.writeAll(name);
        try stdout.writeAll("'\n");
        return;
    }

    // Check if tag already exists
    const tag_path = try std.fmt.allocPrint(allocator, ".git/refs/tags/{s}", .{name});
    defer allocator.free(tag_path);

    if (cwd.access(tag_path, .{})) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: tag '{s}' already exists\n", .{name}) catch "fatal: tag exists\n";
        try stderr.writeAll(msg);
        return;
    } else |_| {}

    // Resolve target (default to HEAD)
    const target_sha = if (target_ref) |ref| blk: {
        // Try as ref first
        const ref_path = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
        defer allocator.free(ref_path);

        if (ref_store.resolve(ref_path)) |sha| {
            break :blk sha;
        } else |_| {}

        // Try as direct SHA
        if (ref.len == 40) {
            break :blk object.hash.fromHex(ref[0..40]) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: Failed to resolve '{s}' as a valid ref.\n", .{ref}) catch "fatal: invalid ref\n";
                try stderr.writeAll(msg);
                return;
            };
        }

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: Failed to resolve '{s}' as a valid ref.\n", .{ref}) catch "fatal: invalid ref\n";
        try stderr.writeAll(msg);
        return;
    } else blk: {
        // Default to HEAD
        const head = ref_store.readHead() catch {
            try stderr.writeAll("fatal: Failed to resolve 'HEAD' as a valid ref.\n");
            return;
        };
        break :blk switch (head) {
            .direct => |s| s,
            .symbolic => |sym| inner: {
                defer allocator.free(sym);
                break :inner ref_store.resolve(sym) catch {
                    try stderr.writeAll("fatal: Failed to resolve 'HEAD' as a valid ref.\n");
                    return;
                };
            },
        };
    };

    var store = object.ObjectStore.init(allocator, ".git");

    // Create annotated or lightweight tag
    const final_sha = if (annotate) blk: {
        const msg = message orelse {
            try stderr.writeAll("fatal: no tag message provided (-m)\n");
            return;
        };

        // Get tagger info
        const tagger = getAuthor(allocator) catch "Unknown <unknown@unknown>";
        defer if (!std.mem.eql(u8, tagger, "Unknown <unknown@unknown>")) allocator.free(tagger);

        const timestamp = std.time.timestamp();

        // Build tag object content
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);

        const target_hex = object.hash.toHex(target_sha);
        try content.appendSlice(allocator, "object ");
        try content.appendSlice(allocator, &target_hex);
        try content.appendSlice(allocator, "\ntype commit\ntag ");
        try content.appendSlice(allocator, name);
        try content.appendSlice(allocator, "\ntagger ");
        try content.appendSlice(allocator, tagger);
        try content.appendSlice(allocator, " ");

        var time_buf: [32]u8 = undefined;
        const time_str = std.fmt.bufPrint(&time_buf, "{d} +0000", .{timestamp}) catch "0 +0000";
        try content.appendSlice(allocator, time_str);
        try content.appendSlice(allocator, "\n\n");
        try content.appendSlice(allocator, msg);
        try content.appendSlice(allocator, "\n");

        // Write tag object
        break :blk try store.write(.tag, content.items);
    } else target_sha;

    // Write tag ref
    cwd.makePath(".git/refs/tags") catch {};

    const tag_file = try cwd.createFile(tag_path, .{});
    defer tag_file.close();

    const sha_hex = object.hash.toHex(final_sha);
    try tag_file.writeAll(&sha_hex);
    try tag_file.writeAll("\n");

    if (annotate) {
        try stdout.writeAll("Created annotated tag '");
    } else {
        try stdout.writeAll("Created tag '");
    }
    try stdout.writeAll(name);
    try stdout.writeAll("'\n");
}

fn getAuthor(allocator: std.mem.Allocator) ![]u8 {
    // Try git config
    const config = std.fs.cwd().readFileAlloc(allocator, ".git/config", 64 * 1024) catch return error.NoAuthor;
    defer allocator.free(config);

    var name: ?[]const u8 = null;
    var email: ?[]const u8 = null;

    var lines = std.mem.splitSequence(u8, config, "\n");
    var in_user = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, "[user]")) {
            in_user = true;
        } else if (trimmed.len > 0 and trimmed[0] == '[') {
            in_user = false;
        } else if (in_user) {
            if (std.mem.startsWith(u8, trimmed, "name")) {
                if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
                    name = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                }
            } else if (std.mem.startsWith(u8, trimmed, "email")) {
                if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
                    email = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                }
            }
        }
    }

    if (name != null and email != null) {
        return try std.fmt.allocPrint(allocator, "{s} <{s}>", .{ name.?, email.? });
    }

    return error.NoAuthor;
}

test "tag list empty" {
    // Would need temp repo
}

test "tag create" {
    // Would need temp repo
}
