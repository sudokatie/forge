// Command handlers

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
pub const hash_object = @import("hash_object.zig");
pub const cat_file = @import("cat_file.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
