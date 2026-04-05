// Index subsystem - staging area

pub const index = @import("index.zig");
pub const entry = @import("entry.zig");

pub const Index = index.Index;
pub const IndexEntry = index.IndexEntry;
pub const TreeCache = index.TreeCache;
pub const TreeCacheEntry = index.TreeCacheEntry;
pub const ResolveUndo = index.ResolveUndo;
pub const ResolveUndoEntry = index.ResolveUndoEntry;

test {
    _ = index;
    _ = entry;
}
