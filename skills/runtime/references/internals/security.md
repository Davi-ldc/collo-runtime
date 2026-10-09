# Security

This reference describes the trust boundary around a worker as the code keeps it: the confinement a worker is born into, what it holds afterwards, every place it writes state another process reads and how that reader reads it, what a worker fault costs, what the egress gateway trusts, the gates in `runtime/tests/conventions.zig` that hold the reading rules in place, and what a compromised worker can still reach. The mechanics belong to the code and its `//!` headers: `zygote/child_boot.zig` and `zygote/worker_boot/` for the confinement, `common/io/restricted_uring.zig` for the worker's ring, `common/worker_state/page/`, `common/ipc/ingress_channel/` and `common/ipc/egress_shared/` for the shared memory, `server/ingress/fault.zig` and `server/ingress/runner/` for the server's reading, and `egress/gateway/runtime/` for the gateway's; [egress.md](egress.md) covers the egress session and its token. Paths are relative to `runtime/src/`, a reference reads `file.zig:symbol`, and the code wins wherever this page disagrees with it.

## The boundary

A worker runs one tenant's code and is untrusted from its first instruction. The process is the hard boundary: a worker runs the routes of one worker definition, every one of them (`server/supervisor/launcher.zig:receiveForkReply` hands it the definition's whole route table), and the workers of one definition share a security cell at the gateway (`server/gateway/manager.zig:securityCellIdForDefinition`). Realms inside a worker separate the routes' state, not their trust: code that escapes the engine reaches everything in its process, the bindings of every route of its definition, the tokens of its requests in flight, its sockets and its mappings among them, so every layer outside the process is built to hold against a worker that runs native code: the kernel confines the process, and the server and the gateway take every byte it writes as hostile input.

## Birth and confinement

The launcher creates the worker's cgroup leaf with its limits before the fork. The zygote's fork loop checks that the leaf is an empty cgroup2 directory (`zygote/worker_boot/cgroup.zig:validateEmptyWorkerCgroupDirFd`) and clones the child into it with `clone3(CLONE_INTO_CGROUP | CLONE_PIDFD)` (`zygote/fork_loop.zig:serveForkRequests`, `common/os.zig:cloneForkWithPidFd`), so the limits hold before the child's first instruction. The zygote is single-threaded at every clone, sets the child's `OOM_SCORE_ADJ_WORKER` and lets the kernel reap it (`fork_loop.zig:installWorkerChildAutoReap`); tenant data reaches the child only after the fork, in `WorkerInit` on its init socket, so the zygote holds none. The child then crosses the rest in this order (`zygote/child_boot.zig:workerChildMainImpl`):

| Step | What | Where | Why there |
| --- | --- | --- | --- |
| 1 | unshare user, mount and network namespaces, mapping uid and gid 0 to the server's own | `zygote/worker_boot/sandbox.zig:applyPostForkNamespaces` | `unshare(CLONE_NEWUSER)` refuses a multithreaded process, and engine work later restarts threads |
| 2 | receive `WorkerInit` within `WORKER_INIT_TIMEOUT_MS`, close every descriptor but the init socket, the trace pipe and those `WorkerInit` brought, check the message, its isolated-network and no-direct-egress flags and each descriptor's kind | `child_boot.zig:closeUnexpectedWorkerFds`, `validateWorkerInit`, `validateWorkerInitFds` | nothing else the zygote holds reaches the worker |
| 3 | map the route table, with every route's bindings, read-only from a sealed memfd, clear the environment to `TZ=UTC` and `LANG=C.UTF-8`, map the page | `child_boot.zig:mapRouteTableReadOnly`, `applyWorkerEnvironmentPolicy` | each route's bindings reach only that route's handler `env`, and `process.env` is empty |
| 4 | check that the child is the leaf's only member and that `memory.high`, `memory.max`, `cpu.max` and `pids.max` hold what `WorkerInit` says, and keep `memory.events.local` open | `worker_boot/cgroup.zig:validateAndOpenWorkerMemoryEventsAt` | no engine or tenant code runs under limits nobody set |
| 5 | prove the process single-threaded | `child_boot.zig` | the next privileges are per thread, and `/proc` is still there to read |
| 6 | set `RLIMIT_NOFILE` to `limits.DEFAULT_MAX_OPEN_FILES` and `RLIMIT_CORE` to 0, set no-new-privileges, make mounts private, mount a tmpfs of `WorkerInit`'s size with mode 0700 and `nosuid,nodev,noexec` over the tmp root the host made, `chroot` into it, drop every capability | `worker_boot/sandbox.zig:applyPreThread` | the namespace's capabilities allow the mount and the chroot, and then go |
| 7 | resume the VM, map the fs index ([boot.md](boot.md#the-child)) | `child_boot.zig` | threads may exist from here, and each inherits no capability |
| 8 | build the ring, start the remaining threads ([boot.md](boot.md#the-child)) | `worker/scheduler/resources.zig:initRestrictedWorkerRing`, `child_boot.zig` | the filter forbids creating rings and threads |
| 9 | make the control socket nonblocking | `child_boot.zig` | the filter lets `fcntl` read flags and not set them |
| 10 | install the seccomp allowlist on every thread with `TSYNC` | `worker_boot/sandbox.zig:applySeccomp` | the last sandbox step, once every thread exists |
| 11 | install the boot token, evaluate the route's entry, send `WorkerReady` ([boot.md](boot.md#the-boot-token-the-routes-entry-and-workerready)) | `child_boot.zig` | the first tenant code runs inside every layer |

There is no PID namespace. Outside its user namespace a worker has the server's uid, the same as every other worker, so the seccomp filter is what keeps it from signalling or tracing them.

## The seccomp filter

The filter is an allowlist built at compile time (`zygote/worker_boot/sandbox.zig:security.buildDenyDirectEgressTemplate`). A foreign architecture kills the process, x32 calls fail on x86-64, and a syscall outside `security.allowed_syscalls` fails with EPERM. The list holds I/O on descriptors the worker already has (`read`, `write`, `recvmsg`, `sendmsg` and their kin), memory management including `mmap` and `mprotect`, futexes, clocks and `getrandom`, signal masks and handlers, `poll`, a thread's own registration (`rseq`, `set_robust_list`) and exit.

Arguments narrow the rest. `io_uring_enter` reaches only the worker's ring and `timerfd_settime` only its timerfd, both patched into the program at install time. `openat`, `mkdirat`, `unlinkat`, `renameat2`, `newfstatat` and `statx` work only relative to `AT_FDCWD`, which the chroot confines, and with fixed flag sets: `openat` takes the access mode, `O_CREAT`, `O_TRUNC`, `O_DIRECTORY` and `O_CLOEXEC` only, and `unlinkat` and `renameat2` take no flag; `fstat` on a descriptor passes in either spelling. `fcntl` takes only `F_GETFD`, `F_GETFL` and `F_GET_SEALS`. An argument compared by value must have a zero high word, and a dirfd is matched on its low word, as the kernel reads it.

Absent from the list, and so denied, are `clone`, `clone3`, `fork` and `execve`, `socket` and `connect`, `io_uring_setup` and `io_uring_register`, `kill` and `tgkill`, `ptrace` and `process_vm_readv`, `mount`, `unshare` and `setns`, and every form of `dup`. `sendmsg` stays, so a worker can attach descriptors it holds to a packet, and every reader refuses such a packet. `mmap` with `PROT_EXEC` and `mprotect` stay because the JIT needs them, so code that escapes the engine can run native code inside its worker; the filter, the namespaces and the chroot bound what that code can ask of the kernel.

## The worker's ring

The worker's io_uring is created disabled, registers its whole fixed-file table, takes a restriction set that admits `POLL_ADD` alone with `IOSQE_FIXED_FILE` required, and only then is enabled (`common/io/restricted_uring.zig:WorkerRing.init`, `restricted_uring.zig:workerRestrictions`). An enabled ring takes no further registration and the filter denies a new ring, so after boot the ring can poll its seven files and do nothing else. `restricted_uring.zig:validateWorkerFixedFiles` checks each slot before registration:

| Slot (`restricted_uring.zig:FixedFile`) | File | Checked as |
| --- | --- | --- |
| `control` | the worker's control socket | AF_UNIX SEQPACKET |
| `wakeup` | the engine's wake eventfd | eventfd |
| `egress_completion` | the wake set's completion eventfd | eventfd |
| `egress_liveness` | the read end of the liveness pipe whose write end the gateway holds | FIFO |
| `timer` | the worker's timerfd | timerfd |
| `ingress_payload_credit` | the payload credit eventfd | eventfd |
| `fs_fault` | the fault socket | AF_UNIX SEQPACKET |

No file can join the table later, so every egress session of a worker is built on the same wake set, and an attach whose liveness pipe differs is refused (`worker/egress/state.zig:State.attach`).

## What a worker cannot reach

Together the layers close these paths:

| Resource | What keeps a worker from it |
| --- | --- |
| the network | its own network namespace, which has no device or route (`zygote/worker_boot/sandbox.zig:namespaces`), and a filter without `socket` or `connect`; its one outbound path is its gateway session ([egress.md](egress.md)) |
| the machine's files | a private mount namespace, a fresh tmpfs root it chroots into, with no `/proc` or `/dev` inside, and path calls admitted only relative to `AT_FDCWD` |
| programs, processes and threads | no `execve`, `clone`, `clone3` or `fork` in the filter, and `pids.max` on its cgroup |
| other processes | no `kill`, `tgkill`, `ptrace` or `process_vm_readv` in the filter, and no `/proc` to find them by |
| privileges | no-new-privileges and an empty capability set, in a user namespace that maps only the server's uid and gid and denies `setgroups` |
| memory and CPU | `memory.high`, `memory.max`, `cpu.max` and `pids.max` on the cgroup it was born into and checked against `WorkerInit` |
| the kernel's io_uring | one ring that polls its fixed files, and no `io_uring_setup` or `io_uring_register` |
| other tenants' memory | a process of its own; it shares memory only with the server and the gateway, through the regions below |

## What a worker holds

| Descriptor or mapping | Comes from | The worker can |
| --- | --- | --- |
| control socket | the zygote's init socket pair | send response descriptors, and attach descriptors the server refuses |
| fault socket | `WorkerInit` | send fault requests |
| payload memfd (`common/ipc/ingress_channel/payload_ring.zig`) | `WorkerInit`, size-sealed, closed once mapped | read and write both rings and all four cursors |
| state page (`common/worker_state/page/mapping.zig`) | `WorkerInit`, size-sealed, closed once mapped | write every byte |
| egress endpoint (`common/ipc/egress_shared/endpoint.zig`) | `WorkerInit` or `egress_attach`, region descriptors closed once mapped | write only the parts its half opens writable |
| egress wake descriptors | the worker's wake set | write both eventfds, hold the gateway's liveness pipe open |
| trace pipe write end | the zygote (`zygote/trace.zig`) | write lines |
| `memory.events.local` | step 4 | read |
| route table and fs index | sealed memfds, mapped read-only | read |
| completion and credit eventfds, timerfd, ring, wake eventfd | `WorkerInit` and its own boot | write the eventfds |

## Surfaces and their readers

Every byte a worker can write in shared memory, and every packet it sends, reaches a reader that takes it as hostile:

| Surface | Reader, thread | Read-once path | A contradiction is |
| --- | --- | --- | --- |
| control socket | the worker's reader lane (`server/ingress/runner/worker_control.zig:drainWorkerControl`) | one `recvmsg` into the lane's buffer (`common/ipc/packet.zig:recvPacketWithFdsScratch`), decoded from it, any descriptor refused (`common/ipc/ingress_channel/receive.zig`) | a worker fault |
| init socket at boot | the launcher | `zygote/host_client.zig:receiveWorkerInitOutcome` | a failed launch |
| `worker_to_server` payload ring | the reader lane | the lane's own read cursor, the worker's write cursor loaded once per operation, each payload checked against where the last one ended (`payload_ring.zig:SharedPayloadView`, `receive.zig:SharedPayloadHolds`), its bytes copied once by their consumer (`SharedPayloadView.heldPayload`) | `payload_ring_invalid` |
| `server_to_worker` read cursor | the lanes writing request bodies | loaded once per write and checked against the lane's own write cursor (`SharedPayloadView.loadCursors`) | `payload_ring_invalid` |
| lifecycle header | the usage drain (`server/supervisor/usage_drain.zig`) | `common/worker_state/page/snapshots.zig:LifecycleSnapshot`, tags kept raw and converted with `std.enums.fromInt` | an unknown state, read as none |
| live slots | the usage drain, at a death | `snapshots.zig:LiveSlotSnapshot.find`: one copy per slot, the state compared as a raw integer, every identity field matched | no match, so a floor record from the dispatch time |
| usage record ring | the usage drain, under `metrics_mutex` | `snapshots.zig:RecordCursor`: the head loaded once, the tail private, each record copied once and kept only under a request the table expects | `usage_record_protocol` |
| completion ring | the reader lane (`server/ingress/runner/worker_completions.zig`) | `page/completion_ring.zig:drainWorkerCompletions`: the head loaded once, the tail in `HostCursors`, each record copied once, validated, the copy handed on | a completion fault |
| console ring | the metrics thread and the teardown (`server/analytics/logs.zig`) | frame headers copied once and checked (`page/console_ring.zig`) | `log_ring_corrupt` |
| fault socket | the reader lane (`server/ingress/runner/fs_fault_control.zig:drainWorkerFsFault`) | decoded from the packet copy; only a request this lane has in flight is served, and no answer carries a descriptor | `fs_fault_request_undecodable` |
| egress command ring, upload pool, release queues | the gateway loop | [egress.md](egress.md#what-each-side-checks) | session removed or dropped |
| eventfds | the lanes and the gateway loop | drained as wakes, never read for content | `channel_failed` when a lane's read fails |
| liveness pipe | the gateway loop | polled for hang-up only (`egress/gateway/readiness.zig`) | session removed |
| trace pipe | the server's trace drain (`server/boot/trace_drain.zig`) | logged as text when tracing is on | nothing |

The rule behind every row is the one `common/worker_state/page.zig` and `common/ipc/egress_shared.zig` state: a reader loads memory a worker can write once into a private copy, validates the copy and uses only the copy; a tag stays a raw integer until a checked conversion; and a cursor the reader owns lives in the reader's memory and reaches shared memory only as a store for the writer's room check, never loaded back (`page/mapping.zig:HostCursors`, `payload_ring.zig:SharedPayloadView.own_cursors`). Payload and extent bytes stay in shared memory, so a worker can garble the bytes of its own requests and responses and never a length or a cursor.

A copy that passes is still the worker's claim. A usage record is kept only under a request the server's request table still expects and is stamped with the identity the server holds (`server/supervisor/usage_drain.zig`); an access record's duration comes from the lane's state, its status is the worker's `http_status` unless the lane answered 502 for a completion that left its stream unanswered (`server/ingress/runner/request_finish.zig:completionLeftNoAnswer`), and a completion's status, CPU and timing fields reach only that worker's records (`page/completion_ring.zig:validateWorkerCompletionRecord`); whether a response head went out is the lane's own HTTP/2 record (`server/ingress/runner/h2_worker_ipc.zig`).

Every SEQPACKET receive takes at most `common/ipc/messages.zig:max_fds_per_message` descriptors, close-on-exec, and closes every one it received when the kernel truncated the packet or its control data or when a zero-length datagram carried some (`common/ipc/packet.zig`). No packet from a worker may carry a descriptor: the reader faults the worker with `unexpected_descriptor` before it decodes such a packet (`server/ingress/runner/worker_control.zig`), and the decoders refuse one as well (`common/ipc/ingress_channel.zig`).

## Worker faults

`server/ingress/fault.zig` puts every failure into a domain: the connection, the worker, the lane or the server. A worker fault (`fault.zig:WorkerFaultReason`) is anything a worker's bytes or memory cause: a short, oversized or unknown packet, a packet with descriptors or with more descriptors than one receive holds, a zero-length datagram with descriptors, an undecodable ingress or fault packet, a descriptor naming no request the worker was sent, an invalid response head or descriptor, a fatal, overrun or out-of-sequence completion ring or an invalid record, contradictory payload-ring cursors, a failed allocation for its packet, a channel errno, a hang-up, an exit, a request outliving its deadline by `hard_timeout_grace_ns` (`server/supervisor/supervisor.zig:default_hard_timeout_grace_ns`), a broken usage or console ring, and an egress session no gateway could replace. Each callee's errors pass through a table that names all of them (`fault.zig:classifyWorkerError`), so an error a callee adds does not compile until someone gives it a domain, and the loop's handlers can return only `fault.zig:LaneFault` (`fault.zig:assertLoopHandlers`).

A fault costs the worker and its own requests. The lane takes the worker out of service (`server/supervisor/pool.zig:Pool.markDead`), answers each of its requests on that lane with 502, with 504 when the grace backstop found the request past its deadline, or with RST_STREAM once its head went out, and writes the reason into the access record and the usage floor. It tells the other lanes through `worker_died`, for which every lane's command queue keeps a reserve (`server/ingress/commands.zig`), and queues the retirement, whose kill, usage drain and cgroup removal run on the reaper and never on the lane (`server/ingress/runner/worker_fault.zig`). Failures on the server's side of the channel record `internal_error` and do not count against the tenant (`worker_fault.zig:errorCodeForFault`). The lane keeps serving every other connection, and a send that would block waits under the request's deadline without becoming a fault (`fault.zig:WorkerOutcome`).

A worker's death reaches its reader lane through its pidfd, which the kernel writes, so a worker can choose when to die and cannot forge a death (`exited`), or through the hang-up of its sockets (`peer_closed`). When its cgroup counts it past `memory.high`, its configured limit, its sentinel thread writes the dead state with reason `memory` on the page and exits the process at once (`worker/runtime/sentinel.zig`), and `memory.max`, 115% of that limit (`common/cgroup.zig:maxBytes`), is the kernel's backstop; either way the death costs only that worker's requests.

The gateway contains its sessions the same way. A session it removes takes only that worker's fetches, the server gives the worker a new session, and the worker keeps serving; a worker that receives a gateway packet it cannot decode detaches and keeps serving too (`worker/egress/gateway_runtime.zig`).

## What the gateway trusts

The gateway holds the network capability, so it trusts only its control socket from the server, whose hello and attaches it decodes whole, and nothing a worker sends. It assigns session ids itself, attaches each session under the security cell the server named, and believes nothing in a fetch start before `common/ipc/egress_token.zig:verify` accepts the token under the hello's key; the session, request, deadline, budget and policy of a fetch come from the verified token alone (`egress/gateway/runtime/worker_flow.zig`). A worker's fetch and body ids mean nothing outside its session (`egress/gateway/router.zig`), and pools, TLS sessions and shards are keyed by cell and policy entry, so one definition's connections never serve another (`egress/gateway/shard.zig:hashFetch`).

What bounds one worker there is its session's active-fetch cap, its cell's cap, the budget of each token it presents and the invalid-command window that ends its session; [egress.md](egress.md#strikes-and-removal) lists the strikes and the removals. The gateway is confined as well (`egress/gateway/sandbox.zig`): its own user and mount namespaces, a read-only tmpfs root holding only the trust store and the resolver files, no capability, no-new-privileges, Landlock where the kernel has it, and a seccomp blocklist installed once its threads exist.

## Gates

| Test in `runtime/tests/conventions.zig` | What it checks |
| --- | --- |
| `server code reads a worker's page only through its snapshots and drains` | `runtime/src/server` outside tests holds no `@atomicLoad`, names no `records_head`, `records_tail`, `.termination_reason`, `.header.state`, `.completion_header`, `.completion_records`, `.log_header` or `.log_bytes`, and lends `.live_slots` only to `LiveSlotSnapshot.find` and `.completed_records` only to `.copy(`; a second test lists the bypasses it must catch |
| `egress ownership boundaries stay one-way` | `worker/egress` imports neither the gateway, the client nor the server, `egress/core` imports no runtime owner, the gateway imports no server module and does not re-export the client, and server code binds only `control`, `launch`, `policy` and `sizing` of the gateway module |
| `egress client does not import worker runtime` | nothing under `runtime/src/egress` imports the worker |
| `workers do not regain a direct gateway fd field` | no source names an `egress_gateway_fd`, so a worker reaches the gateway only through its rings and eventfds |
| `zygote fork loop stays VM-free and allocation-free after prepare` | `serveForkRequests` checks the prepared baseline and single-threadedness and names no VM or allocator call |
| `production error handling stays explicit` | no empty `catch` block, no silent catch-all in a catch switch, no `std.testing` in production source |
| `a guard branch never asserts the negation of its own condition` | no `assert(false)` and no assert of a guard's negation, which ReleaseFast could turn into deleting the guard's `return` |

Each gate matches text and catches only the shapes it searches for. No gate covers the gateway's reads of egress memory, the ingress payload rings, the seccomp allowlist or the worker's fixed files; their layouts are pinned beside each struct and under `runtime/tests/contracts/`, and the module suites test their behavior, such as `zygote/tests/sandbox.zig` for the filter and `common/tests/ipc/slot_snapshot.zig` for the slot copy.

## Open points

A worker reaches its definition's grant. A worker that runs native code can spend the token of every request in flight in its process, since tokens are not kept apart inside one worker (`egress_token.zig`), and every route's token names `egress/gateway/policy.zig:public_https`, so the grant is any public HTTPS origin.

A worker reaches its own budgets. A token admits fetches until its deadline, up to `common/limits/server.zig:request_timeout_ms_max` after admission, and a token that returns after its `request_ended` or after eviction from the session's slots starts a new budget (`egress/gateway/budgets.zig`), so the per-token budget bounds an honest request, and a dishonest worker is bounded by `max_active_fetches_per_worker_session` concurrent fetches and the deadlines of the tokens it kept. Each of those fetches can be a pooled upload whose assembly buffer the gateway allocates at admission, up to 32 MiB with no deadline of its own (`egress/gateway/runtime/upload_flow.zig:registerPendingUpload`), out of the gateway's `EGRESS_GATEWAY_ADDRESS_SPACE_BYTES_MAX` that every tenant shares.

A worker reaches the command queues of the lanes that hold its requests. Its reader lane forwards a response descriptor that names another lane after checking only that the lane exists (`server/ingress/runner/h2_worker_ipc.zig:handleReceived`); the owner checks the request and the worker when it takes the command off its queue and drops a stale one silently. Until then the command holds one of that lane's `server/ingress/lane.zig:Config.command_queue_capacity` places, which every command outside the reserve shares (`commands.zig`), and a refused forward drops the rest of that response (`h2_worker_ipc.zig:forwardDescriptor`).

A worker reaches the trace pipe. It keeps the write end of the zygote's pipe (`child_boot.zig:closeUnexpectedWorkerFds`), and in a Debug build or under `COLLO_BOOT_TRACE=1` or `COLLO_DEBUG=1` the server logs each line it reads at info as `boot-trace` (`server/boot/trace_drain.zig:loggingRequested`), so a worker can write lines into the operator's log; a worker that fills the pipe makes later events of the zygote and the host drop (`zygote/trace.zig`).

A worker can write its completion, credit and egress command eventfds at will. Each write costs its reader lane or the gateway's single loop thread a pass over that worker, and nothing bounds the rate.

The CPU, timing and byte counts a worker reports enter only its own records, and they remain its claim (`page/completion_ring.zig:validateWorkerCompletionRecord`, `server/supervisor/usage_drain.zig`).
