//! Git LFS (Large File Storage) support
//!
//! LFS allows storing large binary files outside the git repository
//! while keeping lightweight pointer files in the repo.
//!
//! ## Pointer Format
//! ```
//! version https://git-lfs.github.com/spec/v1
//! oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
//! size 12345
//! ```
//!
//! ## Usage
//! ```zig
//! const lfs = @import("lfs/mod.zig");
//!
//! // Check if content is an LFS pointer
//! if (lfs.Pointer.isPointer(content)) {
//!     const ptr = try lfs.Pointer.parse(content);
//!     // ptr.oid and ptr.size available
//! }
//!
//! // Create pointer from content
//! const ptr = lfs.Pointer.fromContent(large_file_content);
//! const pointer_content = try ptr.format(allocator);
//! ```

pub const Pointer = @import("pointer.zig").Pointer;
pub const LFS_VERSION = @import("pointer.zig").LFS_VERSION;
pub const MAX_POINTER_SIZE = @import("pointer.zig").MAX_POINTER_SIZE;

pub const Client = @import("api.zig").Client;
pub const ObjectStore = @import("api.zig").ObjectStore;

pub const CleanFilter = @import("filter.zig").CleanFilter;
pub const SmudgeFilter = @import("filter.zig").SmudgeFilter;
pub const isTracked = @import("filter.zig").isTracked;
pub const parseGitAttributes = @import("filter.zig").parseGitAttributes;

test {
    _ = @import("pointer.zig");
    _ = @import("api.zig");
    _ = @import("filter.zig");
}
