//! `collo_network`: the rules of the `network` setting, owned once so that a
//! configuration error states exactly the rule the gateway enforces. The
//! server's configuration parser reads every allow entry and setting with
//! it, the server compiles the configuration's settings into a policy image
//! with it, the egress gateway decodes that image with it, and the
//! gateway's transport matches every hop of every fetch with it.
//!
//! - `pattern.zig`: the grammar of one allow entry and its canonical form,
//!   and the reading of a URL's host.
//! - `address.zig`: the address classes and which of them a fetch may reach.
//! - `setting.zig`: one setting as the configuration declares it, and the
//!   rules a whole setting must keep.
//! - `grant.zig`: grants and policies, the match of a hop before DNS and of
//!   each resolved address after it, and the text of a denial.
//! - `table.zig`: the policy image the server seals into a memfd for the
//!   gateway's hello, its builder, its checks and its decoding.
//!
//! The module imports `collo_limits` only and links no libc, so every
//! process and the JSC-free test lanes can use it. Nothing here keeps
//! mutable global state.

pub const pattern = @import("pattern.zig");
pub const address = @import("address.zig");
pub const setting = @import("setting.zig");
pub const grant = @import("grant.zig");
pub const table = @import("table.zig");

pub const Pattern = pattern.Pattern;
pub const Host = pattern.Host;
pub const UrlHost = pattern.UrlHost;
pub const AddressClass = address.AddressClass;
pub const Setting = setting.Setting;
pub const Grant = grant.Grant;
pub const Policy = grant.Policy;
pub const Scheme = grant.Scheme;
pub const Target = grant.Target;
pub const Admission = grant.Admission;
pub const Decision = grant.Decision;
pub const Denial = grant.Denial;
pub const Origin = grant.Origin;
pub const Table = table.Table;
pub const Builder = table.Builder;
pub const PolicyId = table.PolicyId;

pub const admit = grant.admit;
pub const admitAddress = grant.admitAddress;
pub const writeDenial = grant.writeDenial;
pub const deny_all = grant.deny_all;
pub const public_https = grant.public_https;
