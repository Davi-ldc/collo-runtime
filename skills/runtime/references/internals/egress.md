# Egress

This reference follows an outbound `fetch()` from a worker to the origin and back: the egress gateway process and its sandbox, the control wire between it and the server, the capability token that admits each fetch, the shared-memory session between a worker and the gateway, and what each side checks, strikes and bounds on the way. The mechanics belong to the code and its `//!` headers: the token to `common/ipc/egress_token.zig`, the session's memory to `common/ipc/egress_shared/`, the fetch messages to `common/ipc/egress.zig`, the gateway process to `egress/gateway/`, the server's side to `server/gateway/` and `server/supervisor/launcher.zig`, the worker's side to `worker/egress/`, and the outbound transport to `egress/client/`. Paths are relative to `runtime/src/`, a reference reads `file.zig:symbol`, and the code wins wherever this page disagrees with it. [security.md](security.md) places the gateway inside a worker's trust boundary.

## Processes and threads

The gateway is one process per node and the only one that opens outbound connections. Its main thread runs the loop (`egress/gateway/runtime/root.zig:Gateway.run`) and owns the worker sessions with their token budgets, the router, the active-fetch counts, the pending uploads, the control socket and what the server's hello brought (`egress/gateway/runtime/control_flow.zig:HelloState`). Each shard adds an engine owner thread and `egress/gateway/engine.zig:Config.h2_connector_count` connector threads that run every DNS, TCP and TLS dial; those threads touch only tasks, bodies and the shard's wake eventfd.

On the server, `server/gateway/manager.zig:Manager` holds the current gateway. The thread that spawns it reads its ready report and sends the hello (`server/gateway/process.zig:spawn`), one reader thread per gateway receives its acks and removal reports (`server/gateway/control_client.zig:Client`), each ingress lane mints tokens from its lease (`server/gateway/lease.zig:Lease`), and the launcher thread attaches and reattaches sessions (`server/supervisor/launcher.zig`). A worker runs its side on its event loop thread (`worker/egress/state.zig`).

## The gateway process

`server/gateway/process.zig:spawn` runs the server's binary as `egress/gateway/launch.zig:process_name` with no argument, the control socket at `launch.zig:inherited_control_fd` and an environment of `process.zig:inherited_environment` alone (`RES_OPTIONS`, `LOCALDOMAIN`, `TZ`), so nothing but the hello configures the gateway. It gives the gateway `OOM_SCORE_ADJ_EGRESS_GATEWAY` (`common/limits/process.zig`), waits up to `process.zig:GATEWAY_READY_TIMEOUT_MS` for `gateway_ready`, and sends the hello before the control reader starts, so the hello is the first packet the gateway reads.

The boot order is fixed (`egress/gateway/runtime/root.zig:run`). The sizing plan and the decoder libraries load while `/proc` and the library files are visible. `egress/gateway/sandbox.zig:applyProcessBaseline` then checks that the process is single-threaded, enters a user and a mount namespace and keeps the server's network namespace, lowers `RLIMIT_CORE` to 0, `RLIMIT_NOFILE` to `egress/gateway/sizing.zig:openFilesLimit`, `RLIMIT_NPROC` to `EGRESS_GATEWAY_TASKS_MAX` and `RLIMIT_AS` to `EGRESS_GATEWAY_ADDRESS_SPACE_BYTES_MAX`, mounts a tmpfs over `sandbox.zig:staging_path` with read-only binds of the first CA bundle among `trust_store_sources` and of `resolver_files`, remounts it read-only and chroots into it, drops every capability, sets no-new-privileges and applies a Landlock ruleset that denies every write where the kernel has Landlock. The trust store loads next, the shards start their threads (`egress/gateway/shard_set.zig:Set.startAll`), the readiness ring is built, the seccomp filter goes onto every thread with `TSYNC` (`sandbox.zig:applySeccompAfterThreadsStarted`), and `gateway_ready` comes last, so the server records only a fully sandboxed gateway.

The gateway's filter is a blocklist (`sandbox.zig:blocked_syscalls`). It kills a foreign architecture, fails x32 calls on x86-64, and answers EPERM to `io_uring_setup` and `io_uring_register`, `bind`, `listen` and `accept`, `memfd_create`, every form of `dup` including `fcntl(F_DUPFD)`, `clone`, `fork` and `execve`, namespace and mount calls, `ptrace` and `process_vm_readv`, `bpf`, `kill` and its relatives, and `socket(AF_UNIX)`, since abstract Unix sockets belong to the network namespace it shares with the server. Since the filter forbids new threads and rings, a shard restarts on the threads and rings its first start created (`egress/gateway/shard.zig:Shard.restart`), and a dead ring ends the process.

The hello (`egress/gateway/control.zig:HelloHeader`, `control.zig:PolicyEntry`) carries a 32-byte key drawn for that gateway alone (`common/ipc/egress_token.zig:Key.random`, called from `server/gateway/manager.zig:Manager.spawnRecord`) and the network policy table the manager built once (`Manager.init`). The gateway decodes it whole: a nonzero key, one to `egress/gateway/policy.zig:policies_max` entries in id order, known kinds, flags of 0 or 1 and zero reserved bytes (`control.zig:decodeHello`). Until it arrives the gateway holds the zero key, which verifies nothing, and takes only the hello and shutdown; any other packet first, or a second hello, ends the gateway (`egress/gateway/runtime/control_flow.zig:handleControl`). Both sides scrub the key from their buffers once it is copied (`control.zig:sendHello`, `control_flow.zig:handleControl`). The configuration has no `network` setting, so every table holds the one entry `policy.zig:public_https` (any host, no private networks, no plain HTTP), and `policy.zig:PolicyKind` has the one kind `any_host`; a test harness loosens the entry through `manager.zig:Config.network_policy`.

## The control wire

One SEQPACKET socket per gateway carries the protocol (`egress/gateway/control.zig`). Each packet opens with `control.zig:Header`, the magic `CEB1` and a kind, and every decoder takes exact lengths and known kinds only; both processes compile the file, so a packet that does not decode is corruption.

| Kind | Sender, thread | Carries | Receiver's check |
| --- | --- | --- | --- |
| `gateway_ready` | gateway loop, last boot step | nothing | `control.zig:decodeGatewayReady`, read by `process.zig:recvGatewayReadyBeforeTimeout` |
| `hello` | the server's spawning thread, once | key and policy table | `control.zig:decodeHello`, and the order in `control_flow.zig:handleControl` |
| `attach_worker` | launcher, through `control_client.zig:Client.attachWorker` | request id, security cell, the gateway's half of a session | exact length and `shared_fd_count` descriptors (`control.zig:decode`), then the endpoint's map checks |
| `attach_worker_ack` | gateway loop | status, request id, session id | `control.zig:decodeAttachAck`, and it must name the waiting attach (`control_client.zig:Client.completeAttachAck`) |
| `request_ended` | lanes and the launcher | 1 to `request_ended_entries_max` entries | `control.zig:decodeRequestEnded`: a nonzero session, request id and generation both zero or both nonzero |
| `session_removed` | gateway loop | session id | `control.zig:decodeSessionRemoved`: a nonzero id |
| `shutdown` | server, `process.zig:GatewayProcess.deinit` | nothing | no descriptors, exact length |

The gateway's end is nonblocking. An ack or removal report that finds the socket full waits in a FIFO of `control_flow.zig:pending_control_packet_capacity`, and later packets queue behind it (`control_flow.zig:sendOrQueueControlPacket`). An ack that can be neither sent nor queued removes the session it acknowledged, unreported, since the server never learned its id; a removal report that can be neither sent nor queued ends the gateway, so the server never keeps a worker it believes attached. A server hang-up ends the loop.

On the server the first failure of the channel stops the client for good (`control_client.zig:Client.failChannel`): a send error, a send or ack that misses `control_client.zig:control_timeout_ms`, and every reader error, which covers the hang-up of an exiting gateway, a packet that does not decode and an ack naming no waiting attach. Its callback, `manager.zig:Manager.retireAfterFailure`, takes the record out of `current`, sends SIGKILL and tells the launcher (`manager.zig:Deps.gatewayLost`). A refused attach, which the gateway sends once it holds `Plan.workers_max` sessions, fails that call alone.

## Shards, engines and readiness

`egress/gateway/sizing.zig:Plan.compute` takes the shard count from `shard.zig:defaultShardCountForCpus`, half the CPUs that affinity and the cgroup quota allow, at least 2 and at most 8, and lowers it while fewer than `max(cpus, workers_floor_min)` endpoints would fit the open-file limit. The header of `sizing.zig` says the server sizes its control client from the same plan in `manager.zig`, but only the gateway computes the plan, and the server reads the one constant `sizing.zig:workers_max` (`launcher.zig:lost_sessions_max`). Each shard is an engine with a counting allocator budgeted at `egress/gateway/supervisor_limits.zig:shard_memory`, so a runaway shard fails its own allocations (`egress/gateway/counting_allocator.zig`).

A fetch runs on the shard `shard.zig:hashFetch` picks from its pool key (the security cell and the isolation id of its policy entry), its scheme and its canonical origin, so a cell's fetches to one origin under one entry share that shard's connections. The engine hands the same pair to the transport as the key of every pooled connection and TLS session (`engine.zig:Engine.submit`), and `policy.zig:networkPolicyIsolationId` folds the gateway's limits into the entry's id, so a connection opened for one definition or one entry never serves another.

An error confined to one fetch's publication fails that fetch; any other error out of a collection pass, or a hung-up shard wake eventfd, goes to `egress/gateway/runtime/shard_flow.zig:superviseShardFailure`. It quarantines the shard, stops the engine, ends with an error each fetch whose replay the worker could observe, restarts the engine on the same threads and rings, and resubmits the others under the pool key and policy entry their routes recorded (`egress/gateway/router.zig:Record`). A shard that would exceed `supervisor_limits.zig:shard_restart` restarts in its window, or whose restart fails, ends the gateway, and the server spawns another.

The loop waits on one io_uring (`egress/gateway/readiness.zig:Backend`) built before seccomp and restricted to `POLL_ADD`, `POLL_REMOVE` and `TIMEOUT` (`readiness.zig:gatewayReadinessRestrictions`). It polls the control socket, each shard's wake eventfd, and each session's command eventfd and liveness descriptor, the last for hang-up only, with one-shot polls and a `readiness.zig:wait_tick_ns` timeout. A collection pass takes at most `engine.zig:ready_event_collect_max` events and as many worker scans and leaves the rest for the next pass, and `egress/gateway/publisher.zig` publishes a body batch whole or not at all.

## Backpressure

Before each wait and after each pass the loop measures every session's completion ring and body pool (`egress/gateway/runtime/worker_flow.zig:refreshWorkerBackpressure`, `egress/gateway/backpressure.zig:compute`):

| Level | Enters at | Leaves below | What the body drain does (`backpressure.zig:pressureForLevel`) |
| --- | --- | --- | --- |
| `reduced_chunks` | body pool 60% | 50% | publishes chunks of at most 16 KiB |
| `paused` | completion ring or body pool 75% | 60% | starts no body pull |
| `hard` | completion ring 95% | 95% | as `paused`; the worker's fetches are canceled once per stay, and its session is dropped after `backpressure.zig:hard_drop_grace_ns` |

Only the completion ring reaches `hard`, because a worker that stops draining completions breaks the protocol, while a full body pool means a slow reader, and flow control holds its origin back. Before it takes a chunk the drain checks the worker's free pool and ring bytes against the worst case (`policy.zig:WorkerPressure`), so a publication that still finds either full fails one fetch (`shard_flow.zig:publishBodyChunkBatch`). On the worker, a full command ring or upload pool parks the task in `worker/egress/state.zig:State.pending_uploads`; starts and upload batches leave `common/ipc/egress_shared/packet_ring.zig:command_control_reserve_bytes` free so that cancels and releases still fit, and the gateway writes the worker's completion eventfd after returning upload extents and after a drain that found new drops (`worker_flow.zig:wakeWorkerAfterCommandDrops`).

## The token

A token is 56 bytes (`common/ipc/egress_token.zig:Token`); its tag is the first 16 bytes of HMAC-SHA256 over the 40 bytes before it, under the gateway's key.

| Field | Offset | Holds |
| --- | --- | --- |
| `version` | 0 | `egress_token.zig:version` |
| `kind` | 1 | 1 for a request token, 2 for a boot token; 0 names no kind, so `egress_token.zig:none` is no token |
| `policy_id` | 2 | the route's entry in the hello's table |
| `budget` | 4 | fetches admitted from the token's first verified fetch |
| `session_id` | 8 | the session it was minted for |
| `request_id`, `request_generation` | 16, 24 | the request, both 0 for a boot token |
| `deadline_monotonic_ns` | 32 | the CLOCK_MONOTONIC instant from which it admits nothing |
| `tag` | 40 | the MAC |

An ingress lane mints a request token for each dispatch to a worker that has a session. `server/ingress/runner/dispatch.zig:requestTokenFields` takes the request's deadline fixed at admission, `policy.zig:public_https_id` and `policy.zig:production.max_fetches_per_request`, and `lease.zig:Lease.mint` signs it, or returns `none` when the lease holds no gateway or another gateway than the worker's session. The lease holds a copy of the current key and a dup of the control socket and is renewed only when `Manager.currentGeneration` moves, which the lane loads once per loop pass (`server/ingress/runner/ring_driver.zig:renewEgressLease`), so the request path takes no lock and sends nothing to the gateway. The worker copies the token from its `DispatchWork` into every fetch start and never reads it (`common/ipc/dispatch.zig`).

The boot token admits the fetches of module top-level code while a worker boots. `server/supervisor/worker_factory.zig:bootEgress` gives it the session, `public_https_id` and `policy.zig:production.max_fetches_per_boot`, and `host/launch.zig:Machine.mintBootToken` signs it with the end of the child window as its deadline, `WORKER_INIT_TIMEOUT_MS` after `WorkerInit` is sent, and scrubs its copy of the key. The child installs it in its boot context (`zygote/child_boot.zig`, `common/ipc/dispatch.zig:DispatchWork.initBoot`), and at `WorkerReady` the launcher ends it with an entry whose request id and generation are 0 (`launcher.zig:Deps.egressBootEnded`, `manager.zig:bootEndedCallback`).

`egress_token.zig:verify` compares the tag first, in constant time, and reads the version and kind only once the tag vouched for them, so a forger cannot learn which field it got wrong; the decoder refuses `none` and reads no other byte (`common/ipc/egress.zig:decodeFetchStart`). The zero key verifies nothing, and each gateway has a key of its own, so the tokens of an earlier gateway fail as forged.

The session record keeps `egress/gateway/budgets.zig:per_session_max` budgets keyed by request id and generation (`budgets.zig:SessionBudgets`). `take` finds the token's budget or starts one with the token's budget and deadline, evicting the earliest deadline when every slot is live; a budget past its deadline is a free slot, and nothing sweeps. `refund` returns a fetch that never reached an engine, and `end` drops the budget at `request_ended`, which for a boot token also refuses that token for the rest of the session.

A lane notes each finished request that carried a token (`server/ingress/runner/request_finish.zig`, `lease.zig:Lease.noteEnded`) and sends the pass's entries as one packet (`lease.zig:Lease.flush`, called from `ring_driver.zig:runQueuedWork`), sooner when `control.zig:request_ended_entries_max` entries wait. The send never waits: a refused batch is counted in `Lease.ended_batches_dropped_full` or `Lease.ended_batches_dropped_closed`, and entries for a gateway other than the lease's are dropped with that gateway. The gateway ends each entry's budget, cancels the request's fetches on the shards its session has fetches on (`shard_set.zig:Set.cancelRequest`) and drops its uploads still assembling (`control_flow.zig:endRequests`), skipping sessions it no longer has. A lost entry costs fetches under that token until its deadline.

## Sessions

A worker has one wake set for its life (`common/ipc/egress_shared/session_fds.zig:WakeSet`): the eventfd that wakes the gateway, the one that wakes the worker, and the read ends of two liveness pipes. Every session of the worker is new region memfds on that set (`session_fds.zig:createSessionForWorker`), because the worker's ring registers the completion eventfd and its liveness pipe at boot and no other file afterwards (`common/io/restricted_uring.zig`). The set holds no write end: each session opens its two write ends from the read ends through `/proc/self/fd`, and the server closes its copies once each side has its own (`session_fds.zig:SessionFds.takeWorkerHalf`), so the gateway's death hangs up the worker's pipe and the worker's exit or detach hangs up the gateway's.

A session has four regions of four size-sealed memfds each, the meta, the producer state, the consumer state and the data (`common/ipc/egress_shared/region.zig`), so a side's half is 16 region descriptors and 4 wake descriptors (`session_fds.zig:shared_fd_count`). Every memfd also gets a read-only reopen, each side receives a writable descriptor only for what it writes (`SessionFds.rawForGateway`, `SessionFds.rawForWorker`), and mapping checks each descriptor's access mode, seals and size and the meta's magic, version, role and capacity (`common/ipc/egress_shared/endpoint.zig`), so the kernel refuses a side's writes to the other side's state.

| Region | Size | Producer | The worker writes | The gateway writes |
| --- | --- | --- | --- | --- |
| command ring | `packet_ring.zig:command_ring_capacity` | worker | producer state, data | meta, consumer state |
| completion ring | `packet_ring.zig:completion_ring_capacity` | gateway | consumer state | meta, producer state, data |
| body pool | `body_pool.zig:body_pool_capacity` | gateway | consumer state, its release queue | meta, producer state, consumer state, data |
| upload pool | `body_pool.zig:body_pool_capacity` | worker | producer state, consumer state, data | meta, consumer state, its release queue |

A launch attaches a session when the worker's definition has a grant, which every definition has (`worker_factory.zig:definitionHasEgressGrant`). `manager.zig:Manager.attachWorker` builds the session on the worker's wake set and sends the gateway's half under the security cell, the first 16 bytes of SHA-256 over a label and the definition's name (`manager.zig:securityCellIdForDefinition`). The gateway maps its half, stamps the session id it assigned into the four metas and answers (`egress/gateway/worker_registry.zig:Registry.attachEndpoint`); ids count up from 1 and never repeat within one gateway, so no later session is admitted under an earlier one's tokens. `WorkerInit` carries the worker's half with the boot token. A launch whose attach fails on the control channel, on a gateway spawn or on descriptors the server could not create boots its child detached with its wake descriptors only (`host/launch.zig:LaunchEgress.detached`), and the launcher attaches it after its publish; the gateway's refusal fails the launch with `egress_attach`, and a gateway that is not wired or an incomplete attachment fails it with `egress_gateway_required` (`server/supervisor/launcher.zig:attachForLaunch`).

The gateway removes a session on its own when the worker's liveness pipe hangs up, its command ring fails or it was marked for drop (`worker_flow.zig:removeWorker`): it detaches the session's fetches on its shards, removes its routes and counts, frees its budgets and reports `session_removed`. The control reader passes the report to the launcher (`manager.zig:Deps.sessionLost`), which takes the worker's record off the session and attaches the worker again in its next pass, at most once per `launcher.zig:egress_prewarm_interval_ms`.

A gateway that dies hangs up every attached worker's liveness pipe. The worker's ring reports `egress_closed`, and `worker/egress/gateway_runtime.zig:disconnectWithReason` fails every active fetch and open body with "fetch failed: egress gateway closed", returns the extents it held while the endpoint is still mapped, unmaps it and keeps serving; a later `fetch()` rejects at once with a TypeError (`worker/egress/fetch_runtime.zig:Refusal`). On the server the channel failure retires the record and wakes the launcher, whose reattach pass spawns a gateway no sooner than `egress_prewarm_interval_ms` after the last spawn and then, one live worker per turn, builds a session on the worker's wake set, writes it into the worker's record and sends the worker's half as an `egress_attach` packet on its control socket (`common/ipc/egress_attach.zig:send`). The record changes first, so no token minted after the attach names the old session. A worker whose socket takes nothing within `launcher.zig:egress_attach_send_timeout_ms`, or whose session the gateway refuses, is retired (`launcher.zig:Deps.retireForEgress`). The worker maps the half with its boot checks and refuses one whose liveness pipe is not the one `WorkerInit` carried (`worker/egress/state.zig:State.attach`).

## A fetch, end to end

1. `worker/host/fetch.zig:collo_runtime_fetch` rejects at once, with a TypeError, a fetch from a detached worker or for a request whose `DispatchWork` carries `none` (`fetch_runtime.zig:refusal`). `fetch_runtime.zig:schedule` refuses one past `RuntimeLimits.max_fetches_per_worker` in flight or past the request's `max_fetches_per_request` started, a scheme other than `http:` or `https:`, and a start over the bounds of `common/ipc/fetch_limits.zig`.
2. `worker/egress/upload_runtime.zig:sendStart` encodes the start with the request's token (`egress.zig:encodeFetchStartInto`). A body up to `fetch_limits.zig:request_body_inline_preferred_bytes_max` rides inline; a larger one is flagged pooled with its total length and streams as upload-pool extents that `egress_upload_chunk_batch` packets announce, each with its running total (`upload_runtime.zig:progressPooledBody`).
3. The worker writes the packet into the command ring (`packet_ring.zig:RingView.writePacketReserved`) and wakes the gateway when it may be asleep (`common/ipc/egress_shared/wake.zig:notifyAfterPacketWrite`).
4. The gateway loop drains the session's body-pool releases, then up to `worker_flow.zig:command_drain_batch` commands (`worker_flow.zig:handleWorker`), each copied out with `RingView.readPacket` and decoded from the copy.
5. `worker_flow.zig:admitFetchStart` checks, in order, the tag, the token's session against the session whose ring carried it, the clock and the deadline, the policy id against the hello's table, `max_active_fetches_per_worker_session` and `max_active_fetches_per_security_cell` (`egress/gateway/limit_tracker.zig:Tracker`), unused fetch and body ids in the session (`router.zig:Router.containsIdentity`) and the target shard's quarantine, and only then takes a fetch from the token's budget. It records the route and the counts and hands the fetch to the engine, or to the upload assembler when it is pooled; whatever fails before the handover is undone, and the budget gets its fetch back unless the worker caused the failure (`worker_flow.zig:FetchAdmission`, `isWorkerPolicySubmitError`).
6. `engine.zig:Engine.submit` checks the ids, the header count and bytes, the body size and the response cap against `policy.zig:production`, and submits with the token's policy entry and deadline. The transport checks the scheme and host before DNS and every resolved address after it, on each hop and each redirect (`egress/client/transport/request/policy.zig:EgressPolicy`): `localhost` names, unsafe host bytes and noncanonical IPv4 literals fail, a resolution with any denied address fails whole, public addresses pass, private ones pass only under `allow_private_networks`, and loopback, link-local, metadata and the other reserved classes never pass.
7. The response returns as completion-ring packets: `egress_fetch_head`, `egress_body_chunk_batch` with body-pool handles and cumulative meters, `egress_body_end`, `egress_fetch_error` and `egress_abort_ack`, the first four stamped with the gateway's publish time. An HTTP/2 body arrives still encoded, and the worker decodes it inside its own cgroup within the bounds the head names (`gateway_runtime.zig:installBodyDecoder`).
8. The worker returns each consumed extent through the body pool's release queue and writes the command eventfd once per batch (`worker/egress/gateway_control.zig:noteBodyPoolChunkReleased`, `flushBodyPoolReleases`). The gateway drains the queue (`egress/gateway/runtime/body_release_flow.zig:drainWorkerPoolReleases`), matches each release to its slot ledger (`egress/gateway/sessions.zig:Worker.takeSlotCredit`), returns the extent's flow-control credit to the engine, and removes the route once the engine no longer holds the body.

On the upload pool the roles swap. The gateway copies each extent into the fetch's assembly buffer, checks the running total against the bytes received, releases the extent at once and wakes the worker (`egress/gateway/runtime/upload_flow.zig:applyUploadChunk`). Once the announced length has arrived, the buffer goes to the engine without a copy (`upload_flow.zig:submitAssembledUpload`), and the task keeps it to replay the body on a redirect. An extent that arrives after its fetch was removed goes straight back to the pool.

## What each side checks

| Data | Written by | Read by | How | On a contradiction |
| --- | --- | --- | --- | --- |
| command ring | worker | gateway loop | `write_seq` loaded once per packet, the frame header copied and checked once, the packet copied out (`packet_ring.zig:RingView.readPacket`) | ring fatal, session removed |
| commands | worker | gateway loop | decoded from the copy: kind, flags, reserved fields and every length against the packet and `fetch_limits` before any slice (`common/ipc/egress.zig`) | session removed |
| upload slots | worker | gateway loop | one `common/ipc/egress_shared/slot_snapshot.zig:SlotSnapshot`, validated against the pool, sliced from the copy | session removed |
| upload release cursor | gateway, in memory the worker maps writable | gateway | loaded back, checked against `release_read_seq` and its maximum, the entry stored modulo the queue (`body_pool.zig:BodyPoolView.releaseChunk`) | pool fatal |
| body-pool releases | worker | gateway loop | cursors loaded once per drain, each entry copied once and checked against the gateway's own slot (`BodyPoolView.drainReleasedChunksObserved`) and its slot ledger | session dropped |
| completion ring read cursor | worker | gateway, as writer | loaded once for space and once after publishing, only to decide on a wake (`RingView.writePacketReserved`) | ring fatal, session dropped |
| completion packets | gateway | worker loop | copied out, decoded with the same checks, ids matched to live tasks and bodies (`gateway_runtime.zig:handlePacketBytes`) | the worker detaches and keeps serving |
| body-pool slots | gateway | worker loop | one `SlotSnapshot` per handle (`BodyPoolView.validateChunkRange`) | the worker detaches |
| token | server | gateway loop | `egress_token.zig:verify` on the decoder's copy | fetch refused, strike |

An extent's bytes stay in shared memory, so a producer can still garble its own bytes after the consumer validated the slot, but it can never move a slice, a length or a cursor. Data the origin controls, such as a body that fails to decode, fails its fetch and never the session (`gateway_runtime.zig`).

## Strikes and removal

A well-formed command that breaks a rule counts against the session's window (`sessions.zig:InvalidCommandWindow`): `sessions.zig:max_invalid_commands_per_window` in an `invalid_command_window_ns` window that opens with the first, and the next one removes the session. The strikes are a bad tag, another session's token, either active-fetch cap, a fetch or body id in use and an exhausted budget (`worker_flow.zig:Refusal.isStrike`), a submission error the worker caused (`worker_flow.zig:isWorkerPolicySubmitError`), a cancel or release naming no route, and an upload whose running total disagrees with the bytes received. An expired token, an ended boot token, an unknown policy id, an unreadable clock and a restarting shard fail the fetch without a strike, since an honest fetch can race its deadline and only the server mints policy ids. An honest worker presents a bad tag only for requests in flight across a gateway replacement, at most `max_fetches_per_request` per request (`worker/egress/fetch_runtime.zig`).

The gateway removes the session at once for a command ring that fails its checks, a packet shorter than a kind or of a kind the ring does not carry, a command that does not decode, and an upload extent the pool rejects. It marks the session for drop (`worker_registry.zig:Registry.markForDrop`) when a packet it publishes finds the completion ring full or corrupt (`shard_flow.zig:queuePacket`), when a body publication fails for anything but a full pool or ring, when its release drain fails or a release misses the slot ledger, when its rings cannot be measured, after `hard_drop_grace_ns` at `hard`, and when an engine reports a worker fault. A drop queue that cannot grow falls back to `egress/gateway/drop_queue.zig:forced_capacity` entries, and past those it drops every attached session so that no marked one stays (`worker_registry.zig:Registry.nextDrop`). The server hears of every removal except a failed ack's, the worker keeps serving, and the launcher gives it a new session.

## Limits

| Limit | Value | Where |
| --- | --- | --- |
| token, key and tag | 56, 32 and 16 bytes | `common/ipc/egress_token.zig` |
| `request_ended_entries_max` | 1024 entries per packet | `egress/gateway/control.zig` |
| `policies_max` | `routes_max`, 256 | `egress/gateway/policy.zig`, `common/limits/server.zig` |
| fetches per request token, per boot token | 16, 16 | `policy.zig:production` |
| active fetches per session, per security cell | 64, 1024 | `policy.zig:production` |
| response body, encoded response | `MATERIALIZED_BODY_BYTES_MAX`, 4 MiB | `policy.zig:production`, `common/limits/http_body.zig` |
| request body | `request_body_pooled_bytes_max`, 32 MiB | `policy.zig:production` |
| request and response headers | `max_request_header_count` (256) headers, 64 KiB | `policy.zig:production`, `common/ipc/messages.zig` |
| stall clock, redirects, redirect drain | 5 s, 20, 64 KiB | `policy.zig:production` |
| body chunk | `EGRESS_BODY_CHUNK_BYTES` (64 KiB), 16 KiB under pressure | `policy.zig:production`, `backpressure.zig` |
| `per_session_max` budgets | 12 | `egress/gateway/budgets.zig` |
| invalid commands | 1024 per 60 s | `egress/gateway/sessions.zig` |
| `command_drain_batch`, `control_drain_batch` | 64, 64 | `egress/gateway/runtime/worker_flow.zig`, `egress/gateway/runtime/control_flow.zig` |
| `pending_control_packet_capacity` | `workers_max` + 1 | `egress/gateway/runtime/control_flow.zig` |
| `forced_capacity` | 64 sessions | `egress/gateway/drop_queue.zig` |
| backpressure, `hard_drop_grace_ns` | 60/50%, 75/60%, 95%; 1 s | `egress/gateway/backpressure.zig` |
| `workers_max` | 256 sessions | `egress/gateway/sizing.zig` |
| `fds_per_worker_endpoint`, `reserved_gateway_fds` | 20, 148 | `sizing.zig` |
| shards, `default_max_shards` | max(2, min(cpus / 2, 8)), 1 on one CPU; 64 | `egress/gateway/shard.zig` |
| connectors per shard, engine queue | 2, 1024 | `engine.zig:Config` |
| `ready_event_collect_max` | 1024 events per pass | `egress/gateway/engine.zig` |
| shard restarts | 3 per 5 minutes | `supervisor_limits.zig:shard_restart` |
| shard memory | 256 MiB | `supervisor_limits.zig:shard_memory` |
| `wait_tick_ns`, `wait_ready_max` | 100 ms, 64 | `egress/gateway/readiness.zig` |
| gateway open files, tasks, address space | 65 536, 1024, 4 GiB | `common/limits/process.zig` |
| gateway root tmpfs | 64 KiB, 16 inodes | `common/limits/process.zig` |
| command ring, completion ring, packet | 1 MiB, 4 MiB, 1 MiB | `common/ipc/egress_shared/packet_ring.zig` |
| `command_control_reserve_bytes` | 64 KiB | `packet_ring.zig` |
| each pool | 8 MiB of 16 KiB blocks, 512 slots, 512 release entries | `common/ipc/egress_shared/body_pool.zig` |
| start packet, method, URL, headers, status text | 1 MiB, 32 B, 16 KiB, 64 KiB, 1 KiB | `common/ipc/fetch_limits.zig` |
| inline body, preferred inline, pooled body | the rest of the packet, 16 KiB, 32 MiB | `fetch_limits.zig` |
| a worker's fetches per request, in flight | 16, 64; the first pinned at or below both token budgets by `runtime/tests/contracts/limits.zig` | `common/ipc/messages.zig:WorkerRuntimeBootOptions` |
| upload segments per batch | 128 | `worker/egress/upload_runtime.zig` |
| attach round trip | 1 s | `server/gateway/control_client.zig:control_timeout_ms` |
| gateway ready, reap after a kill | 2 s, 200 ms | `server/gateway/process.zig` |
| `egress_attach` send, spawn interval | 1 s, 1 s | `server/supervisor/launcher.zig` |
| `lost_sessions_max` | 2 × `workers_max` | `launcher.zig` |
| boot token deadline | `WORKER_INIT_TIMEOUT_MS`, 3 s | `common/limits/process.zig` |

The header of `sizing.zig` also says each endpoint holds `fds_per_worker_endpoint` descriptors in the gateway, but `endpoint.zig:mapEndpointTakeForGateway` closes the 16 region descriptors once they are mapped and keeps five, so the open-file plan reserves more than a session holds.

## Open points

Policies have no host patterns: `PolicyKind.any_host` is the only kind, every route's token names `public_https`, and every worker can fetch any public HTTPS origin. The token budget bounds an honest request; a worker that keeps tokens is bounded by its session's active-fetch cap and by the tokens' deadlines, since a token that comes back after its `request_ended`, or after eviction from the session's slots, starts a new budget (`budgets.zig`).

A pooled upload's assembly buffer is allocated at admission at its announced length, up to `max_request_body_bytes`, on the gateway's own heap (`upload_flow.zig:registerPendingUpload`), and it has no deadline of its own: it lives until the body arrives or the fetch, its request or its session ends. A session can hold `max_active_fetches_per_worker_session` of them, 2 GiB, half the address space every tenant's fetches share.

The task that takes that buffer frees it with the gateway's allocator, which comes with it (`egress/client/task.zig:OwnedBody`, `engine.zig:SubmitOptions.owned_body`), so a shard's count and budget never see it. A redirect that keeps the body, a 307 or 308, or a 301 or 302 of any method but POST (`egress/client/transport/request/redirect.zig:redirectTarget`), copies it into the shard's allocator instead (`task.zig:Task.replaceRequest`), so a redirected upload holds up to `max_request_body_bytes` of its shard's budget, and twice that for the moment a later hop copies it again.
