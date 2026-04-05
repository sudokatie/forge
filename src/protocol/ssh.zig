// Git SSH transport - shell out to ssh command

const std = @import("std");
const pktline = @import("pktline.zig");
const hash_mod = @import("../object/hash.zig");

pub const SshUrl = struct {
    user: ?[]const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
};

/// Parse SSH URL (git@host:path or ssh://user@host/path)
pub fn parseSshUrl(allocator: std.mem.Allocator, url: []const u8) !SshUrl {
    // ssh://user@host:port/path
    if (std.mem.startsWith(u8, url, "ssh://")) {
        const rest = url[6..];

        var user: ?[]const u8 = null;
        var host_start: usize = 0;

        if (std.mem.indexOf(u8, rest, "@")) |at_pos| {
            user = try allocator.dupe(u8, rest[0..at_pos]);
            host_start = at_pos + 1;
        }

        const slash_pos = std.mem.indexOf(u8, rest[host_start..], "/") orelse return error.InvalidUrl;
        const host_port = rest[host_start .. host_start + slash_pos];
        const path = rest[host_start + slash_pos ..];

        var host: []const u8 = undefined;
        var port: ?u16 = null;

        if (std.mem.indexOf(u8, host_port, ":")) |colon_pos| {
            host = try allocator.dupe(u8, host_port[0..colon_pos]);
            port = std.fmt.parseInt(u16, host_port[colon_pos + 1 ..], 10) catch null;
        } else {
            host = try allocator.dupe(u8, host_port);
        }

        return SshUrl{
            .user = user,
            .host = host,
            .port = port,
            .path = try allocator.dupe(u8, path),
        };
    }

    // git@host:path (SCP-style)
    if (std.mem.indexOf(u8, url, ":")) |colon_pos| {
        const user_host = url[0..colon_pos];
        const path = url[colon_pos + 1 ..];

        var user: ?[]const u8 = null;
        var host: []const u8 = undefined;

        if (std.mem.indexOf(u8, user_host, "@")) |at_pos| {
            user = try allocator.dupe(u8, user_host[0..at_pos]);
            host = try allocator.dupe(u8, user_host[at_pos + 1 ..]);
        } else {
            host = try allocator.dupe(u8, user_host);
        }

        return SshUrl{
            .user = user,
            .host = host,
            .port = null,
            .path = try allocator.dupe(u8, path),
        };
    }

    return error.InvalidUrl;
}

/// Execute git-upload-pack over SSH
pub fn uploadPack(
    allocator: std.mem.Allocator,
    ssh_url: SshUrl,
) !struct { stdout: []u8, stdin_writer: std.process.Child.StdIn } {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, "ssh");

    if (ssh_url.port) |port| {
        try args.append(allocator, "-p");
        const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
        try args.append(allocator, port_str);
    }

    const target = if (ssh_url.user) |user|
        try std.fmt.allocPrint(allocator, "{s}@{s}", .{ user, ssh_url.host })
    else
        try allocator.dupe(u8, ssh_url.host);
    defer allocator.free(target);

    try args.append(allocator, target);

    const cmd = try std.fmt.allocPrint(allocator, "git-upload-pack '{s}'", .{ssh_url.path});
    defer allocator.free(cmd);
    try args.append(allocator, cmd);

    var child = std.process.Child.init(args.items, allocator);
    child.stdin_behavior = .pipe;
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .pipe;

    try child.spawn();

    // Read initial ref advertisement
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        try stdout.appendSlice(allocator, buf[0..n]);

        // Check if we've received the full advertisement (ends with flush)
        if (std.mem.indexOf(u8, stdout.items, "0000") != null) break;
    }

    return .{
        .stdout = try stdout.toOwnedSlice(allocator),
        .stdin_writer = child.stdin.?,
    };
}

/// Run SSH command and return output
pub fn runSshCommand(
    allocator: std.mem.Allocator,
    ssh_url: SshUrl,
    git_command: []const u8,
) ![]u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, "ssh");

    if (ssh_url.port) |port| {
        try args.append(allocator, "-p");
        const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
        try args.append(allocator, port_str);
    }

    const target = if (ssh_url.user) |user|
        try std.fmt.allocPrint(allocator, "{s}@{s}", .{ user, ssh_url.host })
    else
        try allocator.dupe(u8, ssh_url.host);
    try args.append(allocator, target);

    const cmd = try std.fmt.allocPrint(allocator, "{s} '{s}'", .{ git_command, ssh_url.path });
    try args.append(allocator, cmd);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
        .max_output_bytes = 100 * 1024 * 1024,
    });

    allocator.free(result.stderr);
    return result.stdout;
}

/// Discover refs from SSH remote
pub fn discoverRefs(allocator: std.mem.Allocator, url: []const u8) !struct {
    refs: []RemoteRef,
    capabilities: []const u8,
} {
    const ssh_url = try parseSshUrl(allocator, url);
    defer {
        if (ssh_url.user) |u| allocator.free(u);
        allocator.free(ssh_url.host);
        allocator.free(ssh_url.path);
    }

    const output = try runSshCommand(allocator, ssh_url, "git-upload-pack");
    defer allocator.free(output);

    var refs_list: std.ArrayList(RemoteRef) = .empty;
    errdefer {
        for (refs_list.items) |r| allocator.free(r.name);
        refs_list.deinit(allocator);
    }

    var capabilities: []const u8 = "";
    var first_line = true;

    var decoder = pktline.Decoder.init(output);

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

    return .{
        .refs = try refs_list.toOwnedSlice(allocator),
        .capabilities = capabilities,
    };
}

pub const RemoteRef = struct {
    name: []const u8,
    sha: hash_mod.Sha1,
};

/// Fetch pack from SSH remote
pub fn fetchPack(
    allocator: std.mem.Allocator,
    url: []const u8,
    wants: []const hash_mod.Sha1,
    haves: []const hash_mod.Sha1,
) ![]u8 {
    const ssh_url = try parseSshUrl(allocator, url);
    defer {
        if (ssh_url.user) |u| allocator.free(u);
        allocator.free(ssh_url.host);
        allocator.free(ssh_url.path);
    }

    // Build request
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);

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

    for (haves) |have| {
        const hex = hash_mod.toHex(have);
        const have_content = try std.fmt.allocPrint(allocator, "have {s}\n", .{hex});
        defer allocator.free(have_content);
        const line = try pktline.encode(allocator, have_content);
        defer allocator.free(line);
        try request.appendSlice(allocator, line);
    }

    const done_content = "done\n";
    const done_line = try pktline.encode(allocator, done_content);
    defer allocator.free(done_line);
    try request.appendSlice(allocator, done_line);

    // Execute SSH with input
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, "ssh");

    if (ssh_url.port) |port| {
        try args.append(allocator, "-p");
        const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
        try args.append(allocator, port_str);
    }

    const target = if (ssh_url.user) |user|
        try std.fmt.allocPrint(allocator, "{s}@{s}", .{ user, ssh_url.host })
    else
        try allocator.dupe(u8, ssh_url.host);
    try args.append(allocator, target);

    const cmd = try std.fmt.allocPrint(allocator, "git-upload-pack '{s}'", .{ssh_url.path});
    try args.append(allocator, cmd);

    // Use child process for bi-directional communication
    var child = std.process.Child.init(args.items, allocator);
    child.stdin_behavior = .pipe;
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .ignore;

    try child.spawn();

    // Read ref advertisement first
    var buf: [8192]u8 = undefined;
    var temp: std.ArrayList(u8) = .empty;
    defer temp.deinit(allocator);

    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        try temp.appendSlice(allocator, buf[0..n]);
        if (std.mem.indexOf(u8, temp.items, "0000") != null) break;
    }

    // Send our request
    child.stdin.?.writeAll(request.items) catch return error.WriteFailed;
    child.stdin.?.close();

    // Read pack response
    var pack_data: std.ArrayList(u8) = .empty;
    errdefer pack_data.deinit(allocator);

    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        try pack_data.appendSlice(allocator, buf[0..n]);
    }

    _ = child.wait() catch {};

    // Extract pack from response
    if (std.mem.indexOf(u8, pack_data.items, "PACK")) |pack_start| {
        const result = try allocator.dupe(u8, pack_data.items[pack_start..]);
        pack_data.deinit(allocator);
        return result;
    }

    return try pack_data.toOwnedSlice(allocator);
}

pub const RefUpdate = struct {
    ref_name: []const u8,
    old_sha: hash_mod.Sha1,
    new_sha: hash_mod.Sha1,
};

/// Push pack to SSH remote
pub fn pushPack(
    allocator: std.mem.Allocator,
    url: []const u8,
    ref_updates: []const RefUpdate,
    pack_data: []const u8,
) !void {
    const ssh_url = try parseSshUrl(allocator, url);
    defer {
        if (ssh_url.user) |u| allocator.free(u);
        allocator.free(ssh_url.host);
        allocator.free(ssh_url.path);
    }

    // Build SSH command args
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, "ssh");

    if (ssh_url.port) |port| {
        try args.append(allocator, "-p");
        const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
        try args.append(allocator, port_str);
    }

    const target = if (ssh_url.user) |user|
        try std.fmt.allocPrint(allocator, "{s}@{s}", .{ user, ssh_url.host })
    else
        try allocator.dupe(u8, ssh_url.host);
    try args.append(allocator, target);

    const cmd = try std.fmt.allocPrint(allocator, "git-receive-pack '{s}'", .{ssh_url.path});
    try args.append(allocator, cmd);

    // Start SSH process
    var child = std.process.Child.init(args.items, allocator);
    child.stdin_behavior = .pipe;
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .pipe;

    try child.spawn();

    // Read ref advertisement first
    var buf: [8192]u8 = undefined;
    var advert: std.ArrayList(u8) = .empty;
    defer advert.deinit(allocator);

    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        try advert.appendSlice(allocator, buf[0..n]);
        if (std.mem.indexOf(u8, advert.items, "0000") != null) break;
    }

    // Build push request
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);

    // Send ref updates
    for (ref_updates, 0..) |update, i| {
        const old_hex = hash_mod.toHex(update.old_sha);
        const new_hex = hash_mod.toHex(update.new_sha);

        var line_buf: [256]u8 = undefined;
        const line_content = if (i == 0)
            std.fmt.bufPrint(&line_buf, "{s} {s} {s}\x00report-status side-band-64k\n", .{ old_hex, new_hex, update.ref_name }) catch continue
        else
            std.fmt.bufPrint(&line_buf, "{s} {s} {s}\n", .{ old_hex, new_hex, update.ref_name }) catch continue;

        const line = try pktline.encode(allocator, line_content);
        defer allocator.free(line);
        try request.appendSlice(allocator, line);
    }

    // Flush after ref updates
    try request.appendSlice(allocator, pktline.flush());

    // Append pack data
    try request.appendSlice(allocator, pack_data);

    // Send request
    child.stdin.?.writeAll(request.items) catch return error.WriteFailed;
    child.stdin.?.close();

    // Read response
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(allocator);

    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        try response.appendSlice(allocator, buf[0..n]);
    }

    // Wait for process to complete
    const term = child.wait() catch return error.ProcessFailed;
    if (term.Exited != 0) {
        // Check for error in response
        if (std.mem.indexOf(u8, response.items, "ng ") != null) {
            return error.PushRejected;
        }
    }

    // Check for explicit rejection in response
    if (std.mem.indexOf(u8, response.items, "ng ") != null) {
        return error.PushRejected;
    }
}

/// Discover refs from SSH remote for receive-pack (push)
pub fn discoverRefsForPush(allocator: std.mem.Allocator, url: []const u8) !struct {
    refs: []RemoteRef,
    capabilities: []const u8,
} {
    const ssh_url = try parseSshUrl(allocator, url);
    defer {
        if (ssh_url.user) |u| allocator.free(u);
        allocator.free(ssh_url.host);
        allocator.free(ssh_url.path);
    }

    const output = try runSshCommand(allocator, ssh_url, "git-receive-pack");
    defer allocator.free(output);

    var refs_list: std.ArrayList(RemoteRef) = .empty;
    errdefer {
        for (refs_list.items) |r| allocator.free(r.name);
        refs_list.deinit(allocator);
    }

    var capabilities: []const u8 = "";
    var first_line = true;

    var decoder = pktline.Decoder.init(output);

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

    return .{
        .refs = try refs_list.toOwnedSlice(allocator),
        .capabilities = capabilities,
    };
}

// Tests
test "parse scp url" {
    const allocator = std.testing.allocator;

    const url = try parseSshUrl(allocator, "git@github.com:user/repo.git");
    defer {
        if (url.user) |u| allocator.free(u);
        allocator.free(url.host);
        allocator.free(url.path);
    }

    try std.testing.expectEqualStrings("git", url.user.?);
    try std.testing.expectEqualStrings("github.com", url.host);
    try std.testing.expectEqualStrings("user/repo.git", url.path);
}

test "parse ssh url" {
    const allocator = std.testing.allocator;

    const url = try parseSshUrl(allocator, "ssh://git@github.com/user/repo.git");
    defer {
        if (url.user) |u| allocator.free(u);
        allocator.free(url.host);
        allocator.free(url.path);
    }

    try std.testing.expectEqualStrings("git", url.user.?);
    try std.testing.expectEqualStrings("github.com", url.host);
    try std.testing.expectEqualStrings("/user/repo.git", url.path);
}

test "parse ssh url with port" {
    const allocator = std.testing.allocator;

    const url = try parseSshUrl(allocator, "ssh://user@host:2222/path/repo.git");
    defer {
        if (url.user) |u| allocator.free(u);
        allocator.free(url.host);
        allocator.free(url.path);
    }

    try std.testing.expectEqualStrings("user", url.user.?);
    try std.testing.expectEqualStrings("host", url.host);
    try std.testing.expectEqual(@as(u16, 2222), url.port.?);
}
