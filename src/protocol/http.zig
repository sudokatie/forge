// Git HTTP transport - smart protocol
// Uses curl for HTTP requests (more stable across Zig versions)

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
    const info_url = try buildInfoRefsUrl(allocator, url);
    defer allocator.free(info_url);

    const response = try httpGet(allocator, info_url);
    defer allocator.free(response);

    return try parseRefDiscovery(allocator, response);
}

fn buildInfoRefsUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const base = if (std.mem.endsWith(u8, url, "/"))
        url[0 .. url.len - 1]
    else
        url;

    return try std.fmt.allocPrint(allocator, "{s}/info/refs?service=git-upload-pack", .{base});
}

fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-s", "-L", url },
        .max_output_bytes = 100 * 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    return result.stdout;
}

fn httpPost(allocator: std.mem.Allocator, url: []const u8, content_type: []const u8, body: []const u8) ![]u8 {
    // Write body to temp file
    const tmp_path = "/tmp/forge_post_body";
    {
        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
        defer tmp_file.close();
        try tmp_file.writeAll(body);
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const content_type_header = try std.fmt.allocPrint(allocator, "Content-Type: {s}", .{content_type});
    defer allocator.free(content_type_header);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl", "-s", "-L",
            "-X",   "POST",
            "-H",   content_type_header,
            "-d",   try std.fmt.allocPrint(allocator, "@{s}", .{tmp_path}),
            url,
        },
        .max_output_bytes = 100 * 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    return result.stdout;
}

fn parseRefDiscovery(allocator: std.mem.Allocator, data: []const u8) !RefDiscovery {
    var refs_list: std.ArrayList(RemoteRef) = .empty;
    errdefer {
        for (refs_list.items) |r| allocator.free(r.name);
        refs_list.deinit(allocator);
    }

    var capabilities: []const u8 = "";
    var first_line = true;

    // Skip service announcement
    var start: usize = 0;
    if (std.mem.startsWith(u8, data, "001e# service=git-upload-pack")) {
        start = 0x1e;
        if (data.len > start + 4 and std.mem.eql(u8, data[start .. start + 4], "0000")) {
            start += 4;
        }
    }

    var decoder = pktline.Decoder.init(data[start..]);

    while (try decoder.next()) |line| {
        if (line.len == 0) continue;
        if (line.len < 41) continue;

        const sha = hash_mod.fromHex(line[0..40]) catch continue;

        const rest = line[41..];
        var ref_end = rest.len;
        var caps_start: ?usize = null;

        if (std.mem.indexOf(u8, rest, "\x00")) |nul_pos| {
            ref_end = nul_pos;
            caps_start = nul_pos + 1;
        }

        const ref_name = std.mem.trimRight(u8, rest[0..ref_end], "\n");

        try refs_list.append(allocator, .{
            .name = try allocator.dupe(u8, ref_name),
            .sha = sha,
        });

        if (first_line and caps_start != null) {
            capabilities = try allocator.dupe(u8, std.mem.trimRight(u8, rest[caps_start.?..], "\n"));
            first_line = false;
        }
    }

    return RefDiscovery{
        .refs = try refs_list.toOwnedSlice(allocator),
        .capabilities = capabilities,
        .allocator = allocator,
    };
}

/// Fetch pack file from remote
pub fn fetchPack(
    allocator: std.mem.Allocator,
    url: []const u8,
    wants: []const hash_mod.Sha1,
    haves: []const hash_mod.Sha1,
) ![]u8 {
    const upload_url = try std.fmt.allocPrint(allocator, "{s}/git-upload-pack", .{
        if (std.mem.endsWith(u8, url, "/")) url[0 .. url.len - 1] else url,
    });
    defer allocator.free(upload_url);

    // Build request body
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);

    // Send wants
    for (wants, 0..) |want, i| {
        const hex = hash_mod.toHex(want);
        const line_content = if (i == 0)
            try std.fmt.allocPrint(allocator, "want {s} ofs-delta side-band-64k thin-pack\n", .{hex})
        else
            try std.fmt.allocPrint(allocator, "want {s}\n", .{hex});
        defer allocator.free(line_content);

        const line = try pktline.encode(allocator, line_content);
        defer allocator.free(line);
        try request.appendSlice(allocator, line);
    }

    try request.appendSlice(allocator, pktline.flush());

    // Send haves
    for (haves) |have| {
        const hex = hash_mod.toHex(have);
        const have_content = try std.fmt.allocPrint(allocator, "have {s}\n", .{hex});
        defer allocator.free(have_content);
        const line = try pktline.encode(allocator, have_content);
        defer allocator.free(line);
        try request.appendSlice(allocator, line);
    }

    // Done
    const done_line = try pktline.encode(allocator, "done\n");
    defer allocator.free(done_line);
    try request.appendSlice(allocator, done_line);

    // Send request
    const response = try httpPost(
        allocator,
        upload_url,
        "application/x-git-upload-pack-request",
        request.items,
    );
    defer allocator.free(response);

    // Extract pack data
    return try extractPackFromResponse(allocator, response);
}

fn extractPackFromResponse(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    var pack_data: std.ArrayList(u8) = .empty;
    errdefer pack_data.deinit(allocator);

    var decoder = pktline.Decoder.init(response);

    while (try decoder.next()) |line| {
        if (line.len == 0) continue;

        const channel = line[0];
        const data = line[1..];

        switch (channel) {
            1 => {
                try pack_data.appendSlice(allocator, data);
            },
            2 => {
                // Progress - ignore
            },
            3 => {
                return error.RemoteError;
            },
            else => {
                if (std.mem.startsWith(u8, line, "PACK") or std.mem.startsWith(u8, line, "NAK")) {
                    if (std.mem.startsWith(u8, line, "PACK")) {
                        try pack_data.appendSlice(allocator, line);
                    }
                }
            },
        }
    }

    if (pack_data.items.len == 0) {
        if (std.mem.indexOf(u8, response, "PACK")) |pack_start| {
            try pack_data.appendSlice(allocator, response[pack_start..]);
        }
    }

    return try pack_data.toOwnedSlice(allocator);
}

/// Push pack to remote
pub fn pushPack(
    allocator: std.mem.Allocator,
    url: []const u8,
    ref_updates: []const RefUpdate,
    pack_data: []const u8,
) !void {
    const receive_url = try std.fmt.allocPrint(allocator, "{s}/git-receive-pack", .{
        if (std.mem.endsWith(u8, url, "/")) url[0 .. url.len - 1] else url,
    });
    defer allocator.free(receive_url);

    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);

    // Send ref updates
    for (ref_updates, 0..) |update, i| {
        const old_hex = hash_mod.toHex(update.old_sha);
        const new_hex = hash_mod.toHex(update.new_sha);

        var line_buf: [256]u8 = undefined;
        const line_content = if (i == 0)
            std.fmt.bufPrint(&line_buf, "{s} {s} {s}\x00report-status\n", .{ old_hex, new_hex, update.ref_name }) catch continue
        else
            std.fmt.bufPrint(&line_buf, "{s} {s} {s}\n", .{ old_hex, new_hex, update.ref_name }) catch continue;

        const line = try pktline.encode(allocator, line_content);
        defer allocator.free(line);
        try request.appendSlice(allocator, line);
    }

    try request.appendSlice(allocator, pktline.flush());
    try request.appendSlice(allocator, pack_data);

    const response = try httpPost(
        allocator,
        receive_url,
        "application/x-git-receive-pack-request",
        request.items,
    );
    defer allocator.free(response);

    if (std.mem.indexOf(u8, response, "ng ") != null) {
        return error.PushRejected;
    }
}

pub const RefUpdate = struct {
    ref_name: []const u8,
    old_sha: hash_mod.Sha1,
    new_sha: hash_mod.Sha1,
};

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
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.name, "refs/heads/main")) {
            return "main";
        }
    }
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
}

test "parse ref discovery" {
    const allocator = std.testing.allocator;

    const data = "003da1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 refs/heads/main\n0000";

    var discovery = try parseRefDiscovery(allocator, data);
    defer discovery.deinit();

    try std.testing.expectEqual(@as(usize, 1), discovery.refs.len);
    try std.testing.expectEqualStrings("refs/heads/main", discovery.refs[0].name);
}
