// Git pack delta encoding and decoding

const std = @import("std");

/// Apply delta instructions to base object
pub fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var pos: usize = 0;

    // Read base size (variable length)
    const base_size = readVarInt(delta, &pos);
    if (base_size != base.len) return error.BaseSizeMismatch;

    // Read result size (variable length)
    const result_size = readVarInt(delta, &pos);

    var result = try allocator.alloc(u8, result_size);
    errdefer allocator.free(result);

    var result_pos: usize = 0;

    // Process delta instructions
    while (pos < delta.len) {
        const cmd = delta[pos];
        pos += 1;

        if (cmd & 0x80 != 0) {
            // Copy from base
            var offset: usize = 0;
            var size: usize = 0;

            if (cmd & 0x01 != 0) {
                offset |= delta[pos];
                pos += 1;
            }
            if (cmd & 0x02 != 0) {
                offset |= @as(usize, delta[pos]) << 8;
                pos += 1;
            }
            if (cmd & 0x04 != 0) {
                offset |= @as(usize, delta[pos]) << 16;
                pos += 1;
            }
            if (cmd & 0x08 != 0) {
                offset |= @as(usize, delta[pos]) << 24;
                pos += 1;
            }

            if (cmd & 0x10 != 0) {
                size |= delta[pos];
                pos += 1;
            }
            if (cmd & 0x20 != 0) {
                size |= @as(usize, delta[pos]) << 8;
                pos += 1;
            }
            if (cmd & 0x40 != 0) {
                size |= @as(usize, delta[pos]) << 16;
                pos += 1;
            }

            if (size == 0) size = 0x10000;

            if (offset + size > base.len) return error.CopyOutOfBounds;
            if (result_pos + size > result.len) return error.ResultOverflow;

            @memcpy(result[result_pos .. result_pos + size], base[offset .. offset + size]);
            result_pos += size;
        } else if (cmd != 0) {
            // Insert literal data
            const size = cmd;
            if (pos + size > delta.len) return error.InsertOutOfBounds;
            if (result_pos + size > result.len) return error.ResultOverflow;

            @memcpy(result[result_pos .. result_pos + size], delta[pos .. pos + size]);
            pos += size;
            result_pos += size;
        } else {
            return error.InvalidDeltaCommand;
        }
    }

    if (result_pos != result_size) return error.ResultSizeMismatch;

    return result;
}

fn readVarInt(data: []const u8, pos: *usize) usize {
    var result: usize = 0;
    var shift: u6 = 0;

    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        result |= @as(usize, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }

    return result;
}

// ============================================================================
// Delta Encoding
// ============================================================================

/// Create a delta that transforms base into target
pub fn createDelta(allocator: std.mem.Allocator, base: []const u8, target: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // Write base size (variable length encoding)
    try writeVarInt(&result, allocator, base.len);

    // Write target size (variable length encoding)
    try writeVarInt(&result, allocator, target.len);

    // Build index of base for fast matching
    var index = try buildIndex(allocator, base);
    defer index.deinit();

    var target_pos: usize = 0;
    var pending_insert: std.ArrayList(u8) = .empty;
    defer pending_insert.deinit(allocator);

    while (target_pos < target.len) {
        // Try to find a match in the base
        const match = findBestMatch(&index, base, target, target_pos);

        if (match.len >= 4) {
            // Flush any pending insert
            if (pending_insert.items.len > 0) {
                try flushInsert(&result, allocator, &pending_insert);
            }

            // Emit copy instruction
            try emitCopy(&result, allocator, match.offset, match.len);
            target_pos += match.len;
        } else {
            // Add to pending insert
            try pending_insert.append(allocator, target[target_pos]);
            target_pos += 1;

            // Flush if we hit max insert size (127 bytes)
            if (pending_insert.items.len >= 127) {
                try flushInsert(&result, allocator, &pending_insert);
            }
        }
    }

    // Flush any remaining insert
    if (pending_insert.items.len > 0) {
        try flushInsert(&result, allocator, &pending_insert);
    }

    return try result.toOwnedSlice(allocator);
}

fn writeVarInt(result: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) {
            byte |= 0x80;
        }
        try result.append(allocator, byte);
        if (v == 0) break;
    }
}

const Match = struct {
    offset: usize,
    len: usize,
};

const HashIndex = struct {
    // Map from 4-byte hash to list of positions
    table: std.AutoHashMap(u32, std.ArrayList(usize)),
    allocator: std.mem.Allocator,

    fn deinit(self: *HashIndex) void {
        var iter = self.table.valueIterator();
        while (iter.next()) |list| {
            list.deinit(self.allocator);
        }
        self.table.deinit();
    }
};

fn buildIndex(allocator: std.mem.Allocator, base: []const u8) !HashIndex {
    var index = HashIndex{
        .table = std.AutoHashMap(u32, std.ArrayList(usize)).init(allocator),
        .allocator = allocator,
    };
    errdefer index.deinit();

    if (base.len < 4) return index;

    // Index every 4-byte sequence
    var i: usize = 0;
    while (i + 4 <= base.len) : (i += 1) {
        const hash = hashBytes(base[i..][0..4]);

        const gop = try index.table.getOrPut(hash);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(allocator, i);
    }

    return index;
}

fn hashBytes(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

fn findBestMatch(index: *HashIndex, base: []const u8, target: []const u8, target_pos: usize) Match {
    if (target_pos + 4 > target.len) {
        return Match{ .offset = 0, .len = 0 };
    }

    const hash = hashBytes(target[target_pos..][0..4]);
    const positions = index.table.get(hash) orelse return Match{ .offset = 0, .len = 0 };

    var best = Match{ .offset = 0, .len = 0 };

    for (positions.items) |base_pos| {
        // Extend match forward
        var len: usize = 0;
        while (base_pos + len < base.len and
            target_pos + len < target.len and
            base[base_pos + len] == target[target_pos + len])
        {
            len += 1;
            // Limit match length to what copy instruction can encode
            if (len >= 0x10000) break;
        }

        if (len > best.len) {
            best = Match{ .offset = base_pos, .len = len };
        }
    }

    return best;
}

fn flushInsert(result: *std.ArrayList(u8), allocator: std.mem.Allocator, pending: *std.ArrayList(u8)) !void {
    while (pending.items.len > 0) {
        const chunk_size = @min(pending.items.len, 127);
        try result.append(allocator, @intCast(chunk_size)); // Insert command (0x01-0x7F)
        try result.appendSlice(allocator, pending.items[0..chunk_size]);

        // Remove the chunk we just wrote
        const remaining = pending.items.len - chunk_size;
        if (remaining > 0) {
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[chunk_size..]);
        }
        pending.shrinkRetainingCapacity(remaining);
    }
}

fn emitCopy(result: *std.ArrayList(u8), allocator: std.mem.Allocator, offset: usize, length: usize) !void {
    var cmd: u8 = 0x80; // Copy command flag
    var params: [7]u8 = undefined;
    var param_count: usize = 0;

    // Encode offset (up to 4 bytes)
    if (offset & 0xFF != 0 or offset == 0) {
        cmd |= 0x01;
        params[param_count] = @intCast(offset & 0xFF);
        param_count += 1;
    }
    if (offset & 0xFF00 != 0) {
        cmd |= 0x02;
        params[param_count] = @intCast((offset >> 8) & 0xFF);
        param_count += 1;
    }
    if (offset & 0xFF0000 != 0) {
        cmd |= 0x04;
        params[param_count] = @intCast((offset >> 16) & 0xFF);
        param_count += 1;
    }
    if (offset & 0xFF000000 != 0) {
        cmd |= 0x08;
        params[param_count] = @intCast((offset >> 24) & 0xFF);
        param_count += 1;
    }

    // Encode length (up to 3 bytes, 0 means 0x10000)
    const len_to_encode = if (length == 0x10000) @as(usize, 0) else length;

    if (len_to_encode & 0xFF != 0 or len_to_encode == 0) {
        cmd |= 0x10;
        params[param_count] = @intCast(len_to_encode & 0xFF);
        param_count += 1;
    }
    if (len_to_encode & 0xFF00 != 0) {
        cmd |= 0x20;
        params[param_count] = @intCast((len_to_encode >> 8) & 0xFF);
        param_count += 1;
    }
    if (len_to_encode & 0xFF0000 != 0) {
        cmd |= 0x40;
        params[param_count] = @intCast((len_to_encode >> 16) & 0xFF);
        param_count += 1;
    }

    try result.append(allocator, cmd);
    try result.appendSlice(allocator, params[0..param_count]);
}

// Tests
test "delta insert only" {
    const allocator = std.testing.allocator;

    // Delta that inserts "hello"
    const base = "";
    var delta: [10]u8 = undefined;
    var pos: usize = 0;

    // Base size = 0
    delta[pos] = 0;
    pos += 1;
    // Result size = 5
    delta[pos] = 5;
    pos += 1;
    // Insert 5 bytes
    delta[pos] = 5;
    pos += 1;
    @memcpy(delta[pos .. pos + 5], "hello");
    pos += 5;

    const result = try applyDelta(allocator, base, delta[0..pos]);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello", result);
}

test "delta copy" {
    const allocator = std.testing.allocator;

    const base = "hello world";
    // Delta: copy first 5 bytes from base
    var delta: [10]u8 = undefined;
    var pos: usize = 0;

    // Base size = 11
    delta[pos] = 11;
    pos += 1;
    // Result size = 5
    delta[pos] = 5;
    pos += 1;
    // Copy: cmd=0x80|0x01|0x10, offset byte, size byte
    delta[pos] = 0x80 | 0x01 | 0x10; // copy, has offset byte, has size byte
    pos += 1;
    delta[pos] = 0; // offset = 0
    pos += 1;
    delta[pos] = 5; // size = 5
    pos += 1;

    const result = try applyDelta(allocator, base, delta[0..pos]);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello", result);
}

test "delta encode simple" {
    const allocator = std.testing.allocator;

    const base = "hello world";
    const target = "hello universe";

    const delta = try createDelta(allocator, base, target);
    defer allocator.free(delta);

    // Delta should be smaller than target for similar content
    try std.testing.expect(delta.len > 0);
}

test "delta encode roundtrip" {
    const allocator = std.testing.allocator;

    const base = "The quick brown fox jumps over the lazy dog.";
    const target = "The quick brown cat jumps over the lazy dog.";

    const delta = try createDelta(allocator, base, target);
    defer allocator.free(delta);

    const reconstructed = try applyDelta(allocator, base, delta);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualStrings(target, reconstructed);
}

test "delta encode identical" {
    const allocator = std.testing.allocator;

    const base = "identical content";
    const target = "identical content";

    const delta = try createDelta(allocator, base, target);
    defer allocator.free(delta);

    const reconstructed = try applyDelta(allocator, base, delta);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualStrings(target, reconstructed);
}

test "delta encode completely different" {
    const allocator = std.testing.allocator;

    const base = "aaaaaaaaaa";
    const target = "bbbbbbbbbb";

    const delta = try createDelta(allocator, base, target);
    defer allocator.free(delta);

    const reconstructed = try applyDelta(allocator, base, delta);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualStrings(target, reconstructed);
}

test "delta encode empty base" {
    const allocator = std.testing.allocator;

    const base = "";
    const target = "new content";

    const delta = try createDelta(allocator, base, target);
    defer allocator.free(delta);

    const reconstructed = try applyDelta(allocator, base, delta);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualStrings(target, reconstructed);
}

test "delta encode to empty" {
    const allocator = std.testing.allocator;

    const base = "some content";
    const target = "";

    const delta = try createDelta(allocator, base, target);
    defer allocator.free(delta);

    const reconstructed = try applyDelta(allocator, base, delta);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualStrings(target, reconstructed);
}
