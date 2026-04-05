// Packed refs file parser and writer

const std = @import("std");
const hash_mod = @import("../object/hash.zig");

pub const PackedRef = struct {
    name: []const u8,
    sha: hash_mod.Sha1,
    peeled: ?hash_mod.Sha1, // For annotated tags
};

pub const PackedRefs = struct {
    refs: []PackedRef,
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator, git_dir: []const u8) !PackedRefs {
        const path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
        defer allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                return PackedRefs{ .refs = &.{}, .allocator = allocator };
            }
            return err;
        };
        defer allocator.free(content);

        return try parse(allocator, content);
    }

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !PackedRefs {
        var refs: std.ArrayList(PackedRef) = .empty;
        errdefer {
            for (refs.items) |ref| allocator.free(ref.name);
            refs.deinit(allocator);
        }

        var lines = std.mem.splitSequence(u8, content, "\n");
        var last_ref: ?*PackedRef = null;

        while (lines.next()) |line| {
            // Skip empty lines and comments
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            // Peeled ref (^<sha>) - refers to previous ref
            if (line[0] == '^' and line.len >= 41) {
                if (last_ref) |ref| {
                    ref.peeled = hash_mod.fromHex(line[1..41]) catch null;
                }
                continue;
            }

            // Regular ref: <sha> <refname>
            if (line.len < 41) continue;

            const sha = hash_mod.fromHex(line[0..40]) catch continue;
            const name = std.mem.trimLeft(u8, line[40..], " ");

            try refs.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .sha = sha,
                .peeled = null,
            });

            last_ref = &refs.items[refs.items.len - 1];
        }

        return PackedRefs{
            .refs = try refs.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn lookup(self: PackedRefs, ref_name: []const u8) ?hash_mod.Sha1 {
        for (self.refs) |ref| {
            if (std.mem.eql(u8, ref.name, ref_name)) {
                return ref.sha;
            }
        }
        return null;
    }

    /// Get peeled SHA for annotated tags
    pub fn lookupPeeled(self: PackedRefs, ref_name: []const u8) ?hash_mod.Sha1 {
        for (self.refs) |ref| {
            if (std.mem.eql(u8, ref.name, ref_name)) {
                return ref.peeled orelse ref.sha;
            }
        }
        return null;
    }

    pub fn deinit(self: *const PackedRefs) void {
        for (self.refs) |ref| {
            self.allocator.free(ref.name);
        }
        if (self.refs.len > 0) {
            self.allocator.free(self.refs);
        }
    }
};

/// Write packed-refs file
pub fn write(allocator: std.mem.Allocator, git_dir: []const u8, refs: []const PackedRef) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // Header
    try file.writeAll("# pack-refs with: peeled fully-peeled sorted\n");

    for (refs) |ref| {
        const hex = hash_mod.toHex(ref.sha);
        try file.writeAll(&hex);
        try file.writeAll(" ");
        try file.writeAll(ref.name);
        try file.writeAll("\n");

        if (ref.peeled) |peeled| {
            const peeled_hex = hash_mod.toHex(peeled);
            try file.writeAll("^");
            try file.writeAll(&peeled_hex);
            try file.writeAll("\n");
        }
    }
}

// Tests
test "parse empty" {
    const allocator = std.testing.allocator;
    const parsed = try PackedRefs.parse(allocator, "");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.refs.len);
}

test "parse with comment" {
    const allocator = std.testing.allocator;
    const content =
        \\# pack-refs with: peeled fully-peeled sorted
        \\da39a3ee5e6b4b0d3255bfef95601890afd80709 refs/heads/main
    ;
    const parsed = try PackedRefs.parse(allocator, content);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.refs.len);
    try std.testing.expectEqualStrings("refs/heads/main", parsed.refs[0].name);
}

test "parse with peeled" {
    const allocator = std.testing.allocator;
    const content =
        \\da39a3ee5e6b4b0d3255bfef95601890afd80709 refs/tags/v1.0
        \\^f572d396fae9206628714fb2ce00f72e94f2258f
    ;
    const parsed = try PackedRefs.parse(allocator, content);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.refs.len);
    try std.testing.expect(parsed.refs[0].peeled != null);
}

test "lookup" {
    const allocator = std.testing.allocator;
    const content = "da39a3ee5e6b4b0d3255bfef95601890afd80709 refs/heads/main\n";
    const parsed = try PackedRefs.parse(allocator, content);
    defer parsed.deinit();

    const sha = parsed.lookup("refs/heads/main");
    try std.testing.expect(sha != null);

    const missing = parsed.lookup("refs/heads/nonexistent");
    try std.testing.expect(missing == null);
}
