// forge update-ref - update a reference to a new value

const std = @import("std");
const object = @import("../object/mod.zig");
const refs = @import("../refs/mod.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    var delete = false;
    var ref_name: ?[]const u8 = null;
    var new_value: ?[]const u8 = null;
    var old_value: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-d")) {
            delete = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (ref_name == null) {
                ref_name = arg;
            } else if (new_value == null) {
                new_value = arg;
            } else if (old_value == null) {
                old_value = arg;
            }
        }
    }

    if (ref_name == null) {
        try stderr.writeAll("usage: forge update-ref [-d] <ref> [<newvalue>] [<oldvalue>]\n");
        return;
    }

    var ref_store = refs.RefStore.init(allocator, ".git");
    const cwd = std.fs.cwd();

    if (delete) {
        const ref_path = try std.fmt.allocPrint(allocator, ".git/{s}", .{ref_name.?});
        defer allocator.free(ref_path);

        cwd.deleteFile(ref_path) catch |err| {
            if (err == error.FileNotFound) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: cannot delete ref '{s}': does not exist\n", .{ref_name.?}) catch "error: ref not found\n";
                try stderr.writeAll(msg);
                return;
            }
            return err;
        };
        return;
    }

    if (new_value == null) {
        try stderr.writeAll("error: new value required (use -d to delete)\n");
        return;
    }

    // Parse new SHA
    if (new_value.?.len != 40) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' is not a valid SHA-1\n", .{new_value.?}) catch "fatal: invalid sha\n";
        try stderr.writeAll(msg);
        return;
    }
    const new_sha = object.hash.fromHex(new_value.?[0..40]) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' is not a valid SHA-1\n", .{new_value.?}) catch "fatal: invalid sha\n";
        try stderr.writeAll(msg);
        return;
    };

    // Verify old value if provided
    if (old_value) |old| {
        if (old.len != 40) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' is not a valid SHA-1\n", .{old}) catch "fatal: invalid sha\n";
            try stderr.writeAll(msg);
            return;
        }
        const expected_old = object.hash.fromHex(old[0..40]) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' is not a valid SHA-1\n", .{old}) catch "fatal: invalid sha\n";
            try stderr.writeAll(msg);
            return;
        };

        // Read current value
        const current = ref_store.resolve(ref_name.?) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: cannot lock ref '{s}': ref does not exist\n", .{ref_name.?}) catch "error: ref not found\n";
            try stderr.writeAll(msg);
            return;
        };

        if (!std.mem.eql(u8, &current, &expected_old)) {
            try stderr.writeAll("error: ref value has changed, refusing to update\n");
            return;
        }
    }

    // Update the ref
    try ref_store.update(ref_name.?, new_sha);
}

test "update-ref basic" {
    // Would need temp repo
}
