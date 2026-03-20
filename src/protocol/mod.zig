// Protocol subsystem - HTTP and SSH transports

pub const pktline = @import("pktline.zig");
pub const http = @import("http.zig");

pub const encode = pktline.encode;
pub const Decoder = pktline.Decoder;
pub const parseCapabilities = pktline.parseCapabilities;

pub const discoverRefs = http.discoverRefs;
pub const RefDiscovery = http.RefDiscovery;
pub const RemoteRef = http.RemoteRef;

test {
    _ = pktline;
    _ = http;
}
