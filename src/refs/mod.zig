// References subsystem - branches, tags, HEAD
// TODO: Implement in Task 5

pub const Ref = struct {
    name: []const u8,
    sha: [20]u8,
};

test {
    @import("std").testing.refAllDecls(@This());
}
