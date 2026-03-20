// Git HTTP transport - smart protocol

const std = @import("std");
const pktline = @import("pktline.zig");
const hash_mod = @import("../object/hash.zig");

pub const RemoteRef = struct {
    name: []const u8,
    sha: hash_mod.Sha1,
};

pub const RefDiscovery = struct {
    refs: []RemoteRef,
    capabilities: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RefDiscovery) void {
        for (self.refs) |ref| {
            self.allocator.free(ref.name);
        }
        if (self.refs.len > 0) {
            self.allocator.free(self.refs);
        }
        if (self.capabilities.len > 0) {
            self.allocator.free(self.capabilities);
        }
    }
};

/// Discover refs from a remote repository
pub fn discoverRefs(allocator: std.mem.Allocator, url: []const u8) !RefDiscovery {
    // Build info/refs URL
    const info_url = try buildInfoRefsUrl(allocator, url);
    defer allocator.free(info_url);

    // Fetch via HTTP
    const response = try httpGet(allocator, info_url);
    defer allocator.free(response);

    // Parse pktline response
    return try parseRefDiscovery(allocator, response);
}

fn buildInfoRefsUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    // Handle trailing slash
    const base = if (std.mem.endsWith(u8, url, "/"))
        url[0 .. url.len - 1]
    else
        url;

    // Remove .git suffix for URL construction if present
    const clean_base = if (std.mem.endsWith(u8, base, ".git"))
        base
    else
        base;

    return try std.fmt.allocPrint(allocator, "{s}/info/refs?service=git-upload-pack", .{clean_base});
}

fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    // Parse URL
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Make request
    var response_buffer: std.ArrayList(u8) = .empty;
    defer response_buffer.deinit(allocator);

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .response_storage = .{ .dynamic = &response_buffer },
    }) catch |err| {
        return err;
    };

    if (result.status != .ok) {
        return error.HttpError;
    }

    return try response_buffer.toOwnedSlice(allocator);
}

fn parseRefDiscovery(allocator: std.mem.Allocator, data: []const u8) !RefDiscovery {
    var refs: std.ArrayList(RemoteRef) = .empty;
    errdefer {
        for (refs.items) |r| allocator.free(r.name);
        refs.deinit(allocator);
    }

    var capabilities: []const u8 = "";
    var first_line = true;

    // Skip service announcement line (# service=git-upload-pack)
    var start: usize = 0;
    if (std.mem.startsWith(u8, data, "001e# service=git-upload-pack")) {
        start = 0x1e; // Skip first packet
        // Skip flush
        if (data.len > start + 4 and std.mem.eql(u8, data[start .. start + 4], "0000")) {
            start += 4;
        }
    }

    var decoder = pktline.Decoder.init(data[start..]);

    while (try decoder.next()) |line| {
        // Skip empty lines
        if (line.len == 0) continue;

        // Format: <sha> <refname>[\0<capabilities>]
        if (line.len < 41) continue;

        const sha = hash_mod.fromHex(line[0..40]) catch continue;

        // Find ref name (after space, before NUL or end)
        const rest = line[41..];
        var ref_end = rest.len;
        var caps_start: ?usize = null;

        if (std.mem.indexOf(u8, rest, "\x00")) |nul_pos| {
            ref_end = nul_pos;
            caps_start = nul_pos + 1;
        }

        // Trim newline from ref name
        const ref_name = std.mem.trimRight(u8, rest[0..ref_end], "\n");

        try refs.append(allocator, .{
            .name = try allocator.dupe(u8, ref_name),
            .sha = sha,
        });

        // Capture capabilities from first ref line
        if (first_line and caps_start != null) {
            capabilities = try allocator.dupe(u8, std.mem.trimRight(u8, rest[caps_start.?..], "\n"));
            first_line = false;
        }
    }

    return RefDiscovery{
        .refs = try refs.toOwnedSlice(allocator),
        .capabilities = capabilities,
        .allocator = allocator,
    };
}

/// Find HEAD target from refs
pub fn findHead(refs: []const RemoteRef) ?hash_mod.Sha1 {
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) {
            return ref.sha;
        }
    }
    return null;
}

/// Find default branch (main or master)
pub fn findDefaultBranch(refs: []const RemoteRef) ?[]const u8 {
    // Try main first
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.name, "refs/heads/main")) {
            return "main";
        }
    }
    // Fall back to master
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.name, "refs/heads/master")) {
            return "master";
        }
    }
    return null;
}

// Tests
test "build info refs url" {
    const allocator = std.testing.allocator;

    const url1 = try buildInfoRefsUrl(allocator, "https://github.com/user/repo.git");
    defer allocator.free(url1);
    try std.testing.expectEqualStrings("https://github.com/user/repo.git/info/refs?service=git-upload-pack", url1);

    const url2 = try buildInfoRefsUrl(allocator, "https://github.com/user/repo");
    defer allocator.free(url2);
    try std.testing.expectEqualStrings("https://github.com/user/repo/info/refs?service=git-upload-pack", url2);
}

test "parse ref discovery" {
    const allocator = std.testing.allocator;

    // Simulated response
    const data = "003da1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 refs/heads/main\n0000";

    var discovery = try parseRefDiscovery(allocator, data);
    defer discovery.deinit();

    try std.testing.expectEqual(@as(usize, 1), discovery.refs.len);
    try std.testing.expectEqualStrings("refs/heads/main", discovery.refs[0].name);
}
