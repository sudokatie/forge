// Git pack delta decoding

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
