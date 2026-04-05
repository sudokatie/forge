// Protocol subsystem tests

const std = @import("std");
const protocol = @import("../src/protocol/mod.zig");
const object = @import("../src/object/mod.zig");

test "pktline encode" {
    const allocator = std.testing.allocator;
    const encoded = try protocol.encode(allocator, "hello");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("0009hello", encoded);
}

test "pktline encode larger" {
    const allocator = std.testing.allocator;
    const data = "a" ** 100;
    const encoded = try protocol.encode(allocator, data);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("0068", encoded[0..4]);
    try std.testing.expectEqual(@as(usize, 104), encoded.len);
}

test "pktline decode" {
    var decoder = protocol.Decoder.init("0009hello0000");

    const line = try decoder.next();
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("hello", line.?);

    // Flush packet
    const flush = try decoder.next();
    try std.testing.expect(flush == null);

    try std.testing.expect(decoder.done());
}

test "pktline decode multiple" {
    var decoder = protocol.Decoder.init("0006ab0007cde0000");

    const line1 = try decoder.next();
    try std.testing.expectEqualStrings("ab", line1.?);

    const line2 = try decoder.next();
    try std.testing.expectEqualStrings("cde", line2.?);

    _ = try decoder.next(); // flush
    try std.testing.expect(decoder.done());
}

test "parse capabilities" {
    const line = "abc123 refs/heads/main\x00thin-pack multi_ack";
    const result = protocol.parseCapabilities(line);

    try std.testing.expectEqualStrings("abc123 refs/heads/main", result.ref);
    try std.testing.expectEqualStrings("thin-pack multi_ack", result.caps);
}

test "parse capabilities no caps" {
    const line = "abc123 refs/heads/main";
    const result = protocol.parseCapabilities(line);

    try std.testing.expectEqualStrings("abc123 refs/heads/main", result.ref);
    try std.testing.expectEqualStrings("", result.caps);
}

test "ssh url parse scp style" {
    const allocator = std.testing.allocator;

    const url = try protocol.ssh.parseSshUrl(allocator, "git@github.com:user/repo.git");
    defer {
        if (url.user) |u| allocator.free(u);
        allocator.free(url.host);
        allocator.free(url.path);
    }

    try std.testing.expectEqualStrings("git", url.user.?);
    try std.testing.expectEqualStrings("github.com", url.host);
    try std.testing.expectEqualStrings("user/repo.git", url.path);
}

test "ssh url parse full" {
    const allocator = std.testing.allocator;

    const url = try protocol.ssh.parseSshUrl(allocator, "ssh://git@github.com/user/repo.git");
    defer {
        if (url.user) |u| allocator.free(u);
        allocator.free(url.host);
        allocator.free(url.path);
    }

    try std.testing.expectEqualStrings("git", url.user.?);
    try std.testing.expectEqualStrings("github.com", url.host);
    try std.testing.expectEqualStrings("/user/repo.git", url.path);
}

test "ssh url parse with port" {
    const allocator = std.testing.allocator;

    const url = try protocol.ssh.parseSshUrl(allocator, "ssh://user@host:2222/path/repo.git");
    defer {
        if (url.user) |u| allocator.free(u);
        allocator.free(url.host);
        allocator.free(url.path);
    }

    try std.testing.expectEqualStrings("user", url.user.?);
    try std.testing.expectEqualStrings("host", url.host);
    try std.testing.expectEqual(@as(u16, 2222), url.port.?);
}

test "http build info refs url" {
    const allocator = std.testing.allocator;

    const url = try protocol.http.buildInfoRefsUrl(allocator, "https://github.com/user/repo.git");
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://github.com/user/repo.git/info/refs?service=git-upload-pack",
        url,
    );
}

test "http build info refs url trailing slash" {
    const allocator = std.testing.allocator;

    const url = try protocol.http.buildInfoRefsUrl(allocator, "https://github.com/user/repo/");
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://github.com/user/repo/info/refs?service=git-upload-pack",
        url,
    );
}

test "find default branch" {
    const refs = [_]protocol.http.RemoteRef{
        .{ .name = "HEAD", .sha = undefined },
        .{ .name = "refs/heads/main", .sha = undefined },
        .{ .name = "refs/heads/develop", .sha = undefined },
    };

    const branch = protocol.http.findDefaultBranch(&refs);
    try std.testing.expect(branch != null);
    try std.testing.expectEqualStrings("main", branch.?);
}

test "find default branch master" {
    const refs = [_]protocol.http.RemoteRef{
        .{ .name = "HEAD", .sha = undefined },
        .{ .name = "refs/heads/master", .sha = undefined },
    };

    const branch = protocol.http.findDefaultBranch(&refs);
    try std.testing.expect(branch != null);
    try std.testing.expectEqualStrings("master", branch.?);
}
