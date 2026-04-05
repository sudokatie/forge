// Diff subsystem - Myers diff and patch generation

pub const myers = @import("myers.zig");
pub const patch = @import("patch.zig");

pub const diff = myers.diff;
pub const unifiedDiff = myers.unifiedDiff;
pub const Edit = myers.Edit;
pub const EditType = myers.EditType;

pub const Patch = patch.Patch;
pub const Hunk = patch.Hunk;
pub const HunkLine = patch.HunkLine;
pub const unifiedDiffWithContext = patch.unifiedDiffWithContext;
pub const gitDiffHeader = patch.gitDiffHeader;
pub const applyPatch = patch.applyPatch;

test {
    _ = myers;
    _ = patch;
}
