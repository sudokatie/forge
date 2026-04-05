// Command handlers

// Porcelain commands
pub const init = @import("init.zig");
pub const add = @import("add.zig");
pub const commit = @import("commit.zig");
pub const log = @import("log.zig");
pub const status = @import("status.zig");
pub const diff = @import("diff.zig");
pub const branch = @import("branch.zig");
pub const checkout = @import("checkout.zig");
pub const clone = @import("clone.zig");
pub const fetch = @import("fetch.zig");
pub const push = @import("push.zig");
pub const tag = @import("tag.zig");

// Plumbing commands
pub const hash_object = @import("hash_object.zig");
pub const cat_file = @import("cat_file.zig");
pub const ls_tree = @import("ls_tree.zig");
pub const ls_files = @import("ls_files.zig");
pub const write_tree = @import("write_tree.zig");
pub const commit_tree = @import("commit_tree.zig");
pub const rev_parse = @import("rev_parse.zig");
pub const update_ref = @import("update_ref.zig");
pub const update_index = @import("update_index.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
