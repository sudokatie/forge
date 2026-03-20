// Index subsystem - staging area

pub const index = @import("index.zig");
pub const Index = index.Index;
pub const IndexEntry = index.IndexEntry;

test {
    _ = index;
}
