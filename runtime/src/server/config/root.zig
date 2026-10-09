//! The server configuration: global settings and named worker definitions,
//! each with its resolved settings and its routes, read once at boot from a
//! `collo.json` file or synthesized for a single entry module. Nothing here
//! touches a module on disk or a worker; the route table and the per-route
//! artifacts are built from a `Config` by `server/routes/`.
//!
//! - `model.zig`: the `Config` types, their defaults and their ownership.
//! - `parse.zig`: the file format, validation and the settings cascade.
//! - `synthesize.zig`: the configuration of `collo serve <entry>`.
//! - `pattern.zig`: the route pattern grammar the parser checks and the
//!   route table reads, and the path prefix the server keeps for itself.
//! - `diagnostic.zig`: the message a failed constructor leaves for the
//!   caller.
//!
//! A `Config` is built on one thread at boot and is immutable afterwards, so
//! every thread of the server may read it without a lock for as long as its
//! owner keeps it alive.

const parse_file = @import("parse.zig");
const synthesize_file = @import("synthesize.zig");
const model = @import("model.zig");

pub const pattern = @import("pattern.zig");

pub const Config = model.Config;
pub const Tls = model.Tls;
pub const Analytics = model.Analytics;
pub const Settings = model.Settings;
pub const Limits = model.Limits;
pub const WorkerDefinition = model.WorkerDefinition;
pub const Route = model.Route;
pub const Binding = model.Binding;
pub const BindingValue = model.BindingValue;
pub const DefinitionIndex = model.DefinitionIndex;
pub const RouteIndex = model.RouteIndex;
pub const RouteKey = model.RouteKey;
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;
pub const Error = parse_file.Error;

pub const default_listen = model.default_listen;
pub const default_settings = model.default_settings;
pub const synthesized_route_pattern = synthesize_file.route_pattern;
pub const synthesized_fallback_worker_name = synthesize_file.fallback_worker_name;

pub const load = parse_file.load;
pub const parse = parse_file.parse;
pub const parseListen = parse_file.parseListen;
pub const absolutePath = parse_file.absolutePath;
pub const isWorkerName = parse_file.isWorkerName;
pub const synthesize = synthesize_file.synthesize;
pub const workerName = synthesize_file.workerName;
