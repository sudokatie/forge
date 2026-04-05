// Reference handling - branches, tags, HEAD

const std = @import("std");
const hash_mod = @import("../object/hash.zig");
const packed_mod = @import("packed.zig");
const PackedRefs = packed_mod.PackedRefs;

pub const Ref = struct {
    name: []const u8,
    target: RefTarget,
};

pub const RefTarget = union(enum) {
    /// Direct reference to a commit SHA
    direct: hash_mod.Sha1,
    /// Symbolic reference to another ref
    symbolic: []const u8,
};

pub const RefStore = struct {
    git_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) RefStore {
        return .{
            .git_dir = git_dir,
            .allocator = allocator,
        };
    }

    /// Read HEAD reference
    pub fn readHead(self: *RefStore) !RefTarget {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir});
        defer self.allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 1024) catch |err| {
            if (err == error.FileNotFound) return error.HeadNotFound;
            return err;
        };
        defer self.allocator.free(content);

        // Trim trailing newline
        const trimmed = std.mem.trimRight(u8, content, "\n\r");

        // Check if symbolic ref
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            return RefTarget{ .symbolic = try self.allocator.dupe(u8, trimmed[5..]) };
        }

        // Direct SHA reference (detached HEAD)
        if (trimmed.len >= 40) {
            return RefTarget{ .direct = try hash_mod.fromHex(trimmed[0..40]) };
        }

        return error.InvalidHeadFormat;
    }

    /// Resolve a ref name to its final SHA (follows symbolic refs)
    pub fn resolve(self: *RefStore, ref_name: []const u8) !hash_mod.Sha1 {
        // Try loose ref first
        if (try self.readLooseRef(ref_name)) |target| {
            return switch (target) {
                .direct => |sha| sha,
                .symbolic => |sym| self.resolve(sym),
            };
        }

        // Try packed refs
        const packed_refs = try PackedRefs.load(self.allocator, self.git_dir);
        defer packed_refs.deinit();

        if (packed_refs.lookup(ref_name)) |sha| {
            return sha;
        }

        return error.RefNotFound;
    }

    /// Read a loose ref file
    fn readLooseRef(self: *RefStore, ref_name: []const u8) !?RefTarget {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
        defer self.allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 1024) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer self.allocator.free(content);

        const trimmed = std.mem.trimRight(u8, content, "\n\r");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            return RefTarget{ .symbolic = try self.allocator.dupe(u8, trimmed[5..]) };
        }

        if (trimmed.len >= 40) {
            return RefTarget{ .direct = try hash_mod.fromHex(trimmed[0..40]) };
        }

        return error.InvalidRefFormat;
    }

    /// Write/update a ref
    pub fn update(self: *RefStore, ref_name: []const u8, sha: hash_mod.Sha1) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
        defer self.allocator.free(path);

        // Create parent directories if needed
        if (std.mem.lastIndexOf(u8, path, "/")) |last_slash| {
            std.fs.cwd().makePath(path[0..last_slash]) catch {};
        }

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const hex = hash_mod.toHex(sha);
        try file.writeAll(&hex);
        try file.writeAll("\n");
    }

    /// List all refs (branches and tags)
    pub fn list(self: *RefStore) ![]Ref {
        var refs: std.ArrayList(Ref) = .empty;
        errdefer refs.deinit(self.allocator);

        // List refs/heads (branches)
        try self.listDir(&refs, "refs/heads");
        // List refs/tags
        try self.listDir(&refs, "refs/tags");

        // Add packed refs
        const packed_refs = try PackedRefs.load(self.allocator, self.git_dir);
        defer packed_refs.deinit();

        for (packed_refs.refs) |pref| {
            // Skip if we already have a loose ref with same name
            var found = false;
            for (refs.items) |r| {
                if (std.mem.eql(u8, r.name, pref.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try refs.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, pref.name),
                    .target = .{ .direct = pref.sha },
                });
            }
        }

        return try refs.toOwnedSlice(self.allocator);
    }

    fn listDir(self: *RefStore, refs: *std.ArrayList(Ref), prefix: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, prefix });
        defer self.allocator.free(path);

        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                const ref_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
                if (try self.readLooseRef(ref_name)) |target| {
                    try refs.append(self.allocator, .{
                        .name = ref_name,
                        .target = target,
                    });
                } else {
                    self.allocator.free(ref_name);
                }
            }
        }
    }
};
// Tests
test "parse symbolic ref" {
    const content = "ref: refs/heads/main";
    try std.testing.expect(std.mem.startsWith(u8, content, "ref: "));
    try std.testing.expectEqualStrings("refs/heads/main", content[5..]);
}

test "parse direct ref" {
    const hex = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
    const sha = try hash_mod.fromHex(hex);
    const back = hash_mod.toHex(sha);
    try std.testing.expectEqualStrings(hex, &back);
}

test "packed refs parse empty" {
    const allocator = std.testing.allocator;
    // This will return empty since file doesn't exist
    const packed_refs = try PackedRefs.load(allocator, "/nonexistent");
    defer packed_refs.deinit();
    try std.testing.expectEqual(@as(usize, 0), packed_refs.refs.len);
}
