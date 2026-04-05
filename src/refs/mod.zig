// References subsystem - branches, tags, HEAD

pub const ref = @import("ref.zig");
pub const packed_refs = @import("packed.zig");

pub const Ref = ref.Ref;
pub const RefTarget = ref.RefTarget;
pub const RefStore = ref.RefStore;
pub const PackedRefs = packed_refs.PackedRefs;
pub const PackedRef = packed_refs.PackedRef;

test {
    _ = ref;
    _ = packed_refs;
}
