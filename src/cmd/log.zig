// forge command - TODO

const std = @import("std");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;
    _ = args;
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    try stderr.writeAll("Not yet implemented\n");
}
