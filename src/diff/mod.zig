// Diff subsystem - Myers diff and patch generation
// TODO: Implement in Task 12

pub const Edit = union(enum) {
    insert: []const u8,
    delete: []const u8,
    equal: []const u8,
};

test {
    @import("std").testing.refAllDecls(@This());
}
