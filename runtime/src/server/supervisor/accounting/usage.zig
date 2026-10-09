//! Usage identity: the key that tells whether a usage record for one request
//! attempt was already written. Pure functions over server-assigned
//! identities; no state, so any thread may call them.

const lifecycle = @import("collo_server_lifecycle");
const worker_shared_page = @import("collo_worker_state").page;

/// One request attempt on one worker incarnation. Request slots are reused
/// across generations and worker ids across incarnations, so both generations
/// belong to the key and nothing else does: a field one constructor left unset
/// would still take part in the hash, and the lookups that keep a request from
/// being recorded twice would stop matching the day another constructor set it.
///
/// The key answers whether the server synthesized a record for an attempt
/// (`UsageLog.synthesisState` in `usage_log.zig`). Whether the worker's own
/// record for the request was already written is answered by the request
/// table (`RequestTable.usageRecorded` in `request_table.zig`).
pub const UsageKey = struct {
    request_key: lifecycle.RequestKey,
    worker_key: lifecycle.WorkerKey,
};

pub fn keyFromIdentity(identity: worker_shared_page.LifecycleIdentity) UsageKey {
    return .{
        .request_key = .{
            .lane_id = identity.request_lane_id,
            .slot = identity.request_slot,
            .generation = identity.request_generation,
        },
        .worker_key = .{
            .worker_id = identity.worker_id,
            .worker_generation = identity.worker_generation,
        },
    };
}

/// The request key comes from the record; the worker key is the drained
/// worker's, from the server's table. The record's own worker fields are never
/// read, so a record can only match attempts of the worker whose ring held it.
pub fn keyFromRecord(record: worker_shared_page.CompletedRecord, worker_key: lifecycle.WorkerKey) UsageKey {
    return .{
        .request_key = .{
            .lane_id = record.request_lane_id,
            .slot = record.request_slot,
            .generation = record.request_generation,
        },
        .worker_key = worker_key,
    };
}

/// Whether `record`, drained from the ring of the worker `worker_key` names,
/// belongs to the request attempt `identity`: the external request id and
/// both keys must match, with the worker key taken as in `keyFromRecord`.
pub fn recordMatchesLifecycle(
    record: worker_shared_page.CompletedRecord,
    worker_key: lifecycle.WorkerKey,
    identity: worker_shared_page.LifecycleIdentity,
) bool {
    if (record.request_id != identity.external_request_id)
        return false;
    const record_key = keyFromRecord(record, worker_key);
    const identity_key = keyFromIdentity(identity);
    if (!record_key.request_key.eql(identity_key.request_key))
        return false;
    return record_key.worker_key.eql(identity_key.worker_key);
}
