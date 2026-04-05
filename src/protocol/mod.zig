// Protocol subsystem - HTTP and SSH transports

pub const pktline = @import("pktline.zig");
pub const http = @import("http.zig");
pub const ssh = @import("ssh.zig");

// Packet line exports
pub const encode = pktline.encode;
pub const Decoder = pktline.Decoder;
pub const parseCapabilities = pktline.parseCapabilities;
pub const flush = pktline.flush;
pub const delimiter = pktline.delimiter;

// HTTP exports
pub const discoverRefs = http.discoverRefs;
pub const RefDiscovery = http.RefDiscovery;
pub const RemoteRef = http.RemoteRef;
pub const fetchPack = http.fetchPack;
pub const pushPack = http.pushPack;
pub const RefUpdate = http.RefUpdate;
pub const findHead = http.findHead;
pub const findDefaultBranch = http.findDefaultBranch;

// SSH exports
pub const parseSshUrl = ssh.parseSshUrl;
pub const SshUrl = ssh.SshUrl;
pub const sshDiscoverRefs = ssh.discoverRefs;
pub const sshDiscoverRefsForPush = ssh.discoverRefsForPush;
pub const sshFetchPack = ssh.fetchPack;
pub const sshPushPack = ssh.pushPack;
pub const SshRefUpdate = ssh.RefUpdate;

test {
    _ = pktline;
    _ = http;
    _ = ssh;
}
