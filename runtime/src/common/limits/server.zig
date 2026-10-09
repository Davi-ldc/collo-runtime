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

/// Most routes one worker definition may declare once workers serve several
/// routes; until then the parser accepts exactly one.
pub const routes_per_definition_max: usize = 64;

/// Most routes across every definition. Every route holds two sealed memfds
/// (its module pack and its bindings) open in the server for its whole life,
/// so this bound is also a bound on those descriptors.
pub const routes_max: usize = 256;

/// Longest route pattern, in bytes.
pub const route_pattern_bytes_max: usize = 1024;

/// Most `/`-separated segments in a route pattern or in a request path the
/// route table walks. A request path deeper than this fails the lookup
/// instead of matching, and a pattern deeper than this could never match.
/// Each `:param` segment yields one capture, so this also bounds the
/// captures of one match.
pub const route_path_segments_max: usize = 64;

/// Bytes of every route's module pack together. Packs stay resident in
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

/// Largest `concurrency`: the number of request slots on a worker's shared
/// state page (`LIVE_SLOT_COUNT` in `common/worker_state/page/live_slots.zig`).
pub const worker_concurrency_max: u8 = 2;

/// Largest `timeoutMs`, the wall-clock deadline of one request.
pub const request_timeout_ms_max: u32 = 15 * 60 * 1000;

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
