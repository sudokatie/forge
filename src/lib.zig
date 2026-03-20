// Forge - Git implementation in Zig
//
// Library root - public API for embedding

pub const object = @import("object/mod.zig");
pub const pack = @import("pack/mod.zig");
pub const refs = @import("refs/mod.zig");
pub const index = @import("index/mod.zig");
pub const diff = @import("diff/mod.zig");
pub const protocol = @import("protocol/mod.zig");

// Re-export common types
pub const Sha1 = object.Sha1;
pub const ObjectStore = object.ObjectStore;
pub const Blob = object.Blob;
pub const Tree = object.Tree;
pub const Commit = object.Commit;

test {
    @import("std").testing.refAllDecls(@This());
}
