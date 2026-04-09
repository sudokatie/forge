// Submodule configuration parsing
//
// Parses .gitmodules file and manages submodule configuration.

const std = @import("std");
const hash_mod = @import("../object/hash.zig");

/// A single submodule entry
pub const Submodule = struct {
    /// Name of the submodule (from [submodule "name"])
    name: []const u8,
    /// Path where submodule is checked out
    path: []const u8,
    /// Remote URL
    url: []const u8,
    /// Branch to track (optional)
    branch: ?[]const u8,
    /// Update strategy
    update: UpdateStrategy,
    /// Whether to fetch recursively
    fetch_recurse: bool,
    /// Ignore mode for status
    ignore: IgnoreMode,

    pub const UpdateStrategy = enum {
        checkout,
        rebase,
        merge,
        none,
    };

    pub const IgnoreMode = enum {
        none,
        dirty,
        untracked,
        all,
    };
};

/// Submodule configuration (from .gitmodules)
pub const SubmoduleConfig = struct {
    submodules: []Submodule,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        for (self.submodules) |sm| {
            self.allocator.free(sm.name);
            self.allocator.free(sm.path);
            self.allocator.free(sm.url);
            if (sm.branch) |b| self.allocator.free(b);
        }
        self.allocator.free(self.submodules);
    }

    /// Parse .gitmodules content
    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Self {
        var submodules: std.ArrayListUnmanaged(Submodule) = .empty;
        errdefer {
            for (submodules.items) |sm| {
                allocator.free(sm.name);
                allocator.free(sm.path);
                allocator.free(sm.url);
                if (sm.branch) |b| allocator.free(b);
            }
            submodules.deinit(allocator);
        }

        var current: ?*Submodule = null;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Section header: [submodule "name"]
            if (std.mem.startsWith(u8, trimmed, "[submodule \"")) {
                // Save previous submodule if valid
                if (current) |c| {
                    if (c.path.len > 0 and c.url.len > 0) {
                        try submodules.append(allocator, c.*);
                    }
                    allocator.destroy(c);
                }

                // Parse name
                const name_start = 12; // len("[submodule \"")
                const name_end = std.mem.indexOf(u8, trimmed[name_start..], "\"") orelse continue;
                const name = trimmed[name_start .. name_start + name_end];

                // Create new submodule entry
                const entry = try allocator.create(Submodule);
                entry.* = .{
                    .name = try allocator.dupe(u8, name),
                    .path = "",
                    .url = "",
                    .branch = null,
                    .update = .checkout,
                    .fetch_recurse = false,
                    .ignore = .none,
                };
                current = entry;
            } else if (current) |c| {
                // Key = value
                var kv = std.mem.splitScalar(u8, trimmed, '=');
                const key = std.mem.trim(u8, kv.next() orelse continue, " \t");
                const value = std.mem.trim(u8, kv.rest(), " \t");

                if (std.mem.eql(u8, key, "path")) {
                    if (c.path.len > 0) allocator.free(c.path);
                    c.path = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "url")) {
                    if (c.url.len > 0) allocator.free(c.url);
                    c.url = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "branch")) {
                    if (c.branch) |b| allocator.free(b);
                    c.branch = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "update")) {
                    c.update = if (std.mem.eql(u8, value, "rebase"))
                        .rebase
                    else if (std.mem.eql(u8, value, "merge"))
                        .merge
                    else if (std.mem.eql(u8, value, "none"))
                        .none
                    else
                        .checkout;
                } else if (std.mem.eql(u8, key, "fetchRecurseSubmodules")) {
                    c.fetch_recurse = std.mem.eql(u8, value, "true");
                } else if (std.mem.eql(u8, key, "ignore")) {
                    c.ignore = if (std.mem.eql(u8, value, "dirty"))
                        .dirty
                    else if (std.mem.eql(u8, value, "untracked"))
                        .untracked
                    else if (std.mem.eql(u8, value, "all"))
                        .all
                    else
                        .none;
                }
            }
        }

        // Don't forget the last one
        if (current) |c| {
            if (c.path.len > 0 and c.url.len > 0) {
                try submodules.append(allocator, c.*);
            }
            allocator.destroy(c);
        }

        return Self{
            .submodules = try submodules.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    /// Serialize to .gitmodules format
    pub fn serialize(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        for (self.submodules) |sm| {
            try result.appendSlice(allocator, "[submodule \"");
            try result.appendSlice(allocator, sm.name);
            try result.appendSlice(allocator, "\"]\n\tpath = ");
            try result.appendSlice(allocator, sm.path);
            try result.appendSlice(allocator, "\n\turl = ");
            try result.appendSlice(allocator, sm.url);
            try result.append(allocator, '\n');
            if (sm.branch) |b| {
                try result.appendSlice(allocator, "\tbranch = ");
                try result.appendSlice(allocator, b);
                try result.append(allocator, '\n');
            }
            if (sm.update != .checkout) {
                try result.appendSlice(allocator, "\tupdate = ");
                try result.appendSlice(allocator, @tagName(sm.update));
                try result.append(allocator, '\n');
            }
            if (sm.fetch_recurse) {
                try result.appendSlice(allocator, "\tfetchRecurseSubmodules = true\n");
            }
            if (sm.ignore != .none) {
                try result.appendSlice(allocator, "\tignore = ");
                try result.appendSlice(allocator, @tagName(sm.ignore));
                try result.append(allocator, '\n');
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Find submodule by path
    pub fn findByPath(self: *const Self, path: []const u8) ?*const Submodule {
        for (self.submodules) |*sm| {
            if (std.mem.eql(u8, sm.path, path)) {
                return sm;
            }
        }
        return null;
    }

    /// Find submodule by name
    pub fn findByName(self: *const Self, name: []const u8) ?*const Submodule {
        for (self.submodules) |*sm| {
            if (std.mem.eql(u8, sm.name, name)) {
                return sm;
            }
        }
        return null;
    }
};

// Tests

test "parse empty gitmodules" {
    const allocator = std.testing.allocator;
    var config = try SubmoduleConfig.parse(allocator, "");
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 0), config.submodules.len);
}

test "parse single submodule" {
    const allocator = std.testing.allocator;
    const content =
        \\[submodule "vendor/lib"]
        \\    path = vendor/lib
        \\    url = https://github.com/example/lib.git
    ;
    var config = try SubmoduleConfig.parse(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.submodules.len);
    try std.testing.expectEqualStrings("vendor/lib", config.submodules[0].name);
    try std.testing.expectEqualStrings("vendor/lib", config.submodules[0].path);
    try std.testing.expectEqualStrings("https://github.com/example/lib.git", config.submodules[0].url);
}

test "parse multiple submodules" {
    const allocator = std.testing.allocator;
    const content =
        \\[submodule "lib1"]
        \\    path = vendor/lib1
        \\    url = https://github.com/example/lib1.git
        \\    branch = main
        \\
        \\[submodule "lib2"]
        \\    path = vendor/lib2
        \\    url = https://github.com/example/lib2.git
        \\    update = rebase
    ;
    var config = try SubmoduleConfig.parse(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.submodules.len);
    try std.testing.expectEqualStrings("lib1", config.submodules[0].name);
    try std.testing.expectEqualStrings("main", config.submodules[0].branch.?);
    try std.testing.expectEqualStrings("lib2", config.submodules[1].name);
    try std.testing.expectEqual(Submodule.UpdateStrategy.rebase, config.submodules[1].update);
}

test "find submodule by path" {
    const allocator = std.testing.allocator;
    const content =
        \\[submodule "mylib"]
        \\    path = vendor/mylib
        \\    url = https://example.com/lib.git
    ;
    var config = try SubmoduleConfig.parse(allocator, content);
    defer config.deinit();

    const found = config.findByPath("vendor/mylib");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("mylib", found.?.name);

    const not_found = config.findByPath("nonexistent");
    try std.testing.expect(not_found == null);
}

test "serialize roundtrip" {
    const allocator = std.testing.allocator;
    const content =
        \\[submodule "test"]
        \\    path = libs/test
        \\    url = https://github.com/test/test.git
    ;
    var config = try SubmoduleConfig.parse(allocator, content);
    defer config.deinit();

    const serialized = try config.serialize(allocator);
    defer allocator.free(serialized);

    // Should contain the key parts
    try std.testing.expect(std.mem.indexOf(u8, serialized, "libs/test") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "https://github.com/test/test.git") != null);
}
