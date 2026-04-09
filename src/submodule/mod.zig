// Submodule support - nested repository management
//
// Implements git submodule functionality for nested repositories.

pub const config = @import("config.zig");
pub const status = @import("status.zig");

pub const SubmoduleConfig = config.SubmoduleConfig;
pub const Submodule = config.Submodule;
pub const SubmoduleStatus = status.SubmoduleStatus;
pub const SubmoduleStatusEntry = status.SubmoduleStatusEntry;
pub const SubmoduleStatusChecker = status.SubmoduleStatusChecker;

test {
    @import("std").testing.refAllDecls(@This());
}
