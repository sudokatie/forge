// Git packet line protocol encoding/decoding

const std = @import("std");

/// Encode data as a packet line
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len > 65516) return error.DataTooLong; // Max pktline data

    const total_len = data.len + 4;
    var result = try allocator.alloc(u8, total_len);
    errdefer allocator.free(result);

    // 4-byte hex length prefix
    _ = std.fmt.bufPrint(result[0..4], "{x:0>4}", .{total_len}) catch unreachable;
    @memcpy(result[4..], data);

    return result;
}

/// Create a flush packet (0000)
pub fn flush() []const u8 {
    return "0000";
}

/// Create a delimiter packet (0001)
pub fn delimiter() []const u8 {
    return "0001";
}

/// Create a response end packet (0002)
pub fn responseEnd() []const u8 {
    return "0002";
}

/// Decode packet lines from a stream
pub const Decoder = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Decoder {
        return .{ .data = data, .pos = 0 };
    }

    /// Read next packet, returns null for flush/special packets
    pub fn next(self: *Decoder) !?[]const u8 {
        if (self.pos + 4 > self.data.len) return null;

        // Parse 4-byte hex length
        const len_str = self.data[self.pos .. self.pos + 4];
        const len = std.fmt.parseInt(u16, len_str, 16) catch return error.InvalidLength;

        self.pos += 4;

        // Special packets
        if (len == 0) return null; // flush
        if (len == 1) return null; // delimiter
        if (len == 2) return null; // response-end

        if (len < 4) return error.InvalidLength;

        const data_len = len - 4;
        if (self.pos + data_len > self.data.len) return error.UnexpectedEnd;

        const result = self.data[self.pos .. self.pos + data_len];
        self.pos += data_len;

        return result;
    }

    /// Check if at end
    pub fn done(self: *Decoder) bool {
        return self.pos >= self.data.len;
    }
};

/// Parse capability list from first ref line
pub fn parseCapabilities(line: []const u8) struct { ref: []const u8, caps: []const u8 } {
    // Format: <sha> <refname>\0<capabilities>
    const nul_pos = std.mem.indexOf(u8, line, "\x00");
    if (nul_pos) |pos| {
        return .{
            .ref = line[0..pos],
            .caps = line[pos + 1 ..],
        };
    }
    return .{
        .ref = line,
        .caps = "",
    };
}

// Tests
test "encode basic" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, "hello");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("0009hello", encoded);
}

test "encode larger" {
    const allocator = std.testing.allocator;
    const data = "a" ** 100;
    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("0068", encoded[0..4]);
    try std.testing.expectEqual(@as(usize, 104), encoded.len);
}

test "decode basic" {
    var decoder = Decoder.init("0009hello0000");

    const line = try decoder.next();
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("hello", line.?);

    // Flush packet
    const flush_result = try decoder.next();
    try std.testing.expect(flush_result == null);

    try std.testing.expect(decoder.done());
}

test "decode multiple lines" {
    var decoder = Decoder.init("0006ab0007cde0000");

    const line1 = try decoder.next();
    try std.testing.expectEqualStrings("ab", line1.?);

    const line2 = try decoder.next();
    try std.testing.expectEqualStrings("cde", line2.?);

    // Flush
    _ = try decoder.next();
    try std.testing.expect(decoder.done());
}

test "parse capabilities" {
    const line = "abc123 refs/heads/main\x00thin-pack multi_ack";
    const result = parseCapabilities(line);

    try std.testing.expectEqualStrings("abc123 refs/heads/main", result.ref);
    try std.testing.expectEqualStrings("thin-pack multi_ack", result.caps);
}
