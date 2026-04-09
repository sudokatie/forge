// Merge module - three-way merge algorithm and conflict handling
//
// Implements the core merge algorithm used by rebase, cherry-pick, and merge commands.

pub const merge = @import("merge.zig");
pub const conflict = @import("conflict.zig");

pub const MergeResult = merge.MergeResult;
pub const MergeOptions = merge.MergeOptions;
pub const ConflictStyle = merge.ConflictStyle;
pub const ConflictMarker = conflict.ConflictMarker;
pub const ConflictEntry = conflict.ConflictEntry;

pub const mergeBlobs = merge.mergeBlobs;
pub const mergeTrees = merge.mergeTrees;
