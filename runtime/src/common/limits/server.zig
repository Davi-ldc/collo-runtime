//! Bounds on what one server configuration may declare: the configuration
//! file itself, worker definitions, routes, route patterns, bindings and the
//! module packs built from disk at boot. The configuration parser
//! (`server/config/parse.zig`) rejects a file that exceeds any of them, and
//! the route artifacts (`server/routes/artifacts.zig`) enforce the pack
//! bounds while they build. It must import nothing; `root.zig` says why, and
//! `runtime/tests/contracts/limits.zig` pins the ties to other modules.

/// Largest configuration file read at boot, text bindings included. The
/// parser holds the whole file and its JSON tree in memory at once.
pub const config_file_bytes_max: usize = 1024 * 1024;

/// Most worker definitions in one configuration. Each definition is a pool
/// key of the scheduler and a security cell of the egress gateway.
pub const worker_definitions_max: usize = 256;

/// Longest worker definition name. Names match `[a-z0-9-]` and also serve
/// as the deploy segment of the module specifiers a definition's routes are
/// packed under.
pub const worker_name_bytes_max: usize = 64;

/// Most routes one worker definition may declare. A worker of the definition
/// serves all of them and boots every one before it reports ready, so this
/// also bounds a cold start's module work and a worker's realms.
pub const routes_per_definition_max: usize = 64;

/// Most routes across every definition.
pub const routes_max: usize = 256;

/// Longest route pattern, in bytes.
pub const route_pattern_bytes_max: usize = 1024;

/// Most `/`-separated segments in a route pattern or in a request path the
/// route table walks. A request path deeper than this fails the lookup
/// instead of matching, and a pattern deeper than this could never match.
/// Each `:param` segment yields one capture, so this also bounds the
/// captures of one match.
pub const route_path_segments_max: usize = 64;

/// Bytes of every definition's module pack together. Packs stay resident in
/// sealed memfds from boot until shutdown, so this bounds the shared memory
/// the server pins for code. One pack is also bounded by
/// `max_pack_bytes` in `common/ipc/module_pack.zig`.
pub const pack_bytes_total_max: u64 = 256 * 1024 * 1024;

/// Most bindings one route may declare.
pub const bindings_per_route_max: usize = 64;

/// Longest binding name. Names match `[A-Za-z_][A-Za-z0-9_]*`.
pub const binding_name_bytes_max: usize = 128;

/// Largest serialized bindings blob of one route: a u32 count, then a u32
/// length and the bytes of every name and value. The worker refuses a
/// larger blob (`bytes_max` in `common/ipc/route_bindings.zig`).
pub const binding_bytes_per_route_max: usize = 512 * 1024;

/// Smallest `memoryMiB` a definition may set. It is a sanity floor that
/// turns a unit mistake into a configuration error instead of a worker that
/// dies during boot, not a measured requirement.
pub const worker_memory_mib_min: u32 = 16;

/// Largest `memoryMiB` a definition may set: a sanity ceiling that keeps a
/// typo from becoming a cgroup limit larger than any machine the server runs
/// on.
pub const worker_memory_mib_max: u32 = 64 * 1024;

/// Largest `concurrency`, the requests one worker holds at once. Every
/// worker's state page has this many live slots whatever its definition sets
/// (`LIVE_SLOT_COUNT` in `common/worker_state/page/live_slots.zig` derives
/// from it), so raising it costs every worker. The server sizes each worker's
/// request table and pool slots from it, and the gateway each session's
/// budgets. A definition that sets no `concurrency` gets the default in
/// `default_settings` (`server/config/model.zig`).
pub const worker_concurrency_max: u8 = 16;

/// Largest `timeoutMs`, the wall-clock deadline of one request.
pub const request_timeout_ms_max: u32 = 15 * 60 * 1000;

/// Largest `cpuMs`, the CPU time one request may use: the VM thread's while
/// the request owns it, plus the crypto pool's on the request's jobs. Crypto
/// jobs run beside the VM thread, so a request's CPU can grow faster than its
/// wall time, and `cpuMs` is not capped at the definition's `timeoutMs`.
pub const request_cpu_ms_max: u32 = request_timeout_ms_max;

/// Most entries one `network.allow` list may hold. Every gateway holds every
/// entry, and it matches a fetch's host against each grant of the fetch's
/// policy on every hop, so a list that needs more hosts names a common
/// `*.suffix` instead.
pub const network_allow_entries_max: usize = 256;

/// Most entries across every `network` value one configuration declares. It
/// bounds, with `network_allow_entry_bytes_max`, the rules of the policy table
/// the server hands each gateway.
pub const network_allow_entries_total_max: usize = 4096;

/// Longest `network.allow` entry: `*.`, a host name at the DNS bound
/// (`max_name_bytes` in `common/dns_name.zig`) and `:65535`, which
/// `runtime/tests/contracts/limits.zig` ties together. A bracketed IPv6
/// literal with a port is shorter.
pub const network_allow_entry_bytes_max: usize = 261;

comptime {
    if (worker_concurrency_max < 1)
        @compileError("a worker must hold at least one request");
    if (request_cpu_ms_max < 1)
        @compileError("cpuMs must admit at least one millisecond");
    if ("[ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255]:65535".len > network_allow_entry_bytes_max)
        @compileError("the longest IPv6 entry must fit the entry bound");
    if (network_allow_entries_max > network_allow_entries_total_max)
        @compileError("one allow list must fit the configuration's total");
}

comptime {
    // The shortest pattern with the most segments, `/a` repeated, must fit
    // the byte bound, or the segment bound could never be reached.
    if (route_path_segments_max * 2 > route_pattern_bytes_max)
        @compileError("route patterns must be able to reach the segment bound");
    // Every definition declares at least one route.
    if (routes_max < worker_definitions_max)
        @compileError("the route bound must admit one route per definition");
    if (worker_memory_mib_min > worker_memory_mib_max)
        @compileError("memory bounds are inverted");
}
