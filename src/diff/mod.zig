// Diff subsystem - Myers diff and patch generation

pub const myers = @import("myers.zig");
pub const diff = myers.diff;
pub const unifiedDiff = myers.unifiedDiff;
pub const Edit = myers.Edit;
pub const EditType = myers.EditType;

test {
    _ = myers;
}
