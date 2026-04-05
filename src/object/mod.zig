// Object subsystem - Git object model

pub const hash = @import("hash.zig");
pub const blob = @import("blob.zig");
pub const tree = @import("tree.zig");
pub const commit = @import("commit.zig");
pub const tag = @import("tag.zig");
pub const store = @import("store.zig");

// Re-export types
pub const Sha1 = hash.Sha1;
pub const Blob = blob.Blob;
pub const Tree = tree.Tree;
pub const TreeEntry = tree.TreeEntry;
pub const Commit = commit.Commit;
pub const Tag = tag.Tag;
pub const ObjectStore = store.ObjectStore;
pub const ObjectType = store.ObjectType;

test {
    @import("std").testing.refAllDecls(@This());
}
