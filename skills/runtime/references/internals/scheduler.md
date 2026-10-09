# The scheduler

This document covers how the server keeps the workers of each worker definition: the pool that hands out request slots and holds the requests that wait, the launcher thread that turns a pool's claim into a published worker, the reaper thread that retires workers, how a worker's death is noticed, and the caps that bound all of it. The code is in `runtime/src/server/supervisor/` (`pool.zig`, `launcher.zig`, `reaper/`, `supervisor.zig`, `worker_table.zig`, `worker_registry.zig`, `worker_factory.zig`, `scheduler_limits.zig`) and in `runtime/src/common/limits/pool.zig`, and their `//!` headers own the mechanics; the lane's side of a dispatch, a finish and a death is in [request.md](request.md). References name a file and a symbol in it, as in `pool.zig:Pool.acquire`. A bare file name is in `server/supervisor/` or `server/ingress/` (its `runner/` included), a name two directories share carries its directory (`reaper/root.zig`, `runner/root.zig`), and any other path is relative to `runtime/src/`.

## The supervisor and its records

`supervisor.zig:Supervisor` keeps one pool per worker definition (`pools[d]`) and one worker record per pool table entry, entry `e` of pool `d` at `records[d * pool_workers_max + e]`. Both are allocated at `init` and freed at `deinit`, so a record pointer stays valid after its worker leaves, and holders tell the workers one record serves apart by its key (`worker_table.zig:Record.key`). The supervisor has no lock of its own; the locks below belong to the pools, the records, the launcher and the reaper.

The launcher thread alone builds records and assigns worker keys (`worker_registry.zig:buildRecord`), filling a record while its entry is launching, when no other thread can see it (`worker_table.zig:Record.occupy`). The reaper empties a record once its pool says no lane holds or reads the worker (`worker_table.zig:Record.vacate`). At shutdown the exiting thread carries out what the reaper's queue still holds (`reaper/root.zig:Reaper.drainRetirements`), then tears down every worker a record still holds without asking its pool, since every thread that could use one has stopped (`supervisor.zig:Supervisor.deinit`). A live worker's egress session is the one record field the pool's mutex guards: the launcher writes it (`supervisor.zig:Supervisor.setWorkerEgress`, `dropEgressSession`) and the lanes read it (`workerEgress`).

| Lock | Guards | Order |
| --- | --- | --- |
| `pool.zig:Pool.mutex` | a pool's table, slots, waiters and reader tenures, and the record fields `worker_table.zig` names | before a lane's command-queue mutex and never taken with one held; inside a record's `metrics_mutex` in one place (`analytics_drain.zig`) |
| `worker_table.zig:Record.metrics_mutex` | the page mapping, the ring marks and the drain cursors of a worker; spans each drain of its usage and console rings | before the request table's mutex |
| `request_table.zig:RequestTable.mutex` | a worker's request table | a leaf |
| `worker_table.zig:Record.send_mutex` | a worker's send scratch and its server-to-worker payload ring | nests with neither of the two above |
| `launcher.zig:Launcher.mutex` | submissions, gateway and session losses, counters | a leaf, never held across a call |
| `reaper/root.zig:Reaper.mutex` | the retire queue and counters | a leaf; the reaper takes a pool's mutex only inside a pool method and calls out with neither held |

## The pool

`pool.zig:Pool` is a plain structure under one mutex, with no thread, no I/O and no clock, and it allocates only at `init`. Its table has `pool_workers_max` entries, each empty, launching, live, retiring or dead. A live entry points at its worker's record and has the definition's `concurrency` slots, kept as a bit per slot with the lane that holds it, and a slot belongs to one request of one lane from the `acquire` or handoff that takes it to the `release` that gives it back. The waiters are a ring of at most `pool_waiters_max` requests, each a lane, a request key and a deadline, and `launching` counts the launches in flight.

`Pool.acquire` takes the lowest free slot of the most recently used live worker that has one, the lowest entry on a tie (`pool.zig:mostRecentFreeEntry`). That order is the pool's free list: there is no separate list, and each entry carries a `last_use` stamp that every take and give-back advances. Load packs onto warm workers this way, and idle ones stay idle until the reaper retires them. A published worker that serves no waiter starts at the cold end, with `last_use` 0 (`Pool.publish`).

A request that finds no free slot becomes the newest waiter, and a full FIFO answers `.full`, which the lane turns into 503. A freed slot goes to the head waiter at once (`Pool.release`), and a published worker's slots go to the head waiters, oldest first (`Pool.publish`); each handoff carries the slot and a reader grant, and its caller posts it as `dispatch_ready` to the waiter's lane, or dispatches in place when the waiter is a request of its own lane (`request_finish.zig:handOn`). A waiter whose deadline passed is dropped on the way, since its lane answers it (`pool.zig:popLiveWaiter`). Free slots and waiters therefore never coexist, which `Pool.acquire` asserts, and no retry timer exists. A request that ends while it waits leaves the FIFO through `Pool.cancelWaiter`, a scan of at most `pool_waiters_max` entries under the mutex.

`Pool.growthWanted` holds when the memory gate is open, fewer than `launches_max` launches are in flight, an entry is empty (launching, live, retiring and dead entries all count as taken), and more requests wait than the launches in flight will serve: `waiter_count > launching × concurrency` (`pool.zig:growthWantedLocked`). A lane asks when one of its requests starts to wait and after a death it owns, the reaper asks after each removal, and the metrics thread and the launcher ask after a death they announce; each submits to the launcher when the answer holds, with a `launcher.zig:GrowthReason`, and the launcher claims again for a definition after each publish. The answer is advisory, so the launcher's claim decides again under the mutex and takes an empty entry for the launch (`Pool.launchStarted`), which the launch holds until `publish` or `launchEnded`. When growth is refused and the pool has no live worker and no launch in flight, `Pool.takeStranded` hands its waiters out for an immediate 503, since nothing would serve them before their deadlines.

The memory gate is the reaper's last reading of node memory against `fork_deny_percent` (`supervisor.zig:Supervisor.memoryGate`). The reaper caches the used percentage at each periodic pass and each demand-reclaim reading (`reaper/root.zig:readPressure`), so a growth check costs one atomic load; the re-reads inside a reap leave the cache alone. The launcher's claim reads the cache again (`Supervisor.claimLaunch`) and wakes the reaper's demand reclaim when the gate refuses, or when a launch goes ahead at or above `autoscale_high_water_percent`.

One lane at a time reads a worker's output, and the pool decides which. Every slot a lane takes comes with a `ReaderGrant`, which the lane discharges before it dispatches and also when it gives the slot back unused (`pool.zig:grantReader`, `worker_registration.zig:dischargeReaderGrant`):

| `pool.zig:ReaderGrant` | When | The lane that took the slot |
| --- | --- | --- |
| `you_become_reader` | the worker has no reader | registers the worker's output channels and reads them under the new epoch for the whole tenure |
| `already` | the lane reads the worker, another lane reads a busy worker, or a release was asked in this tenure already | nothing; the reader forwards this request's output |
| `transfer_from` | the worker was idle and another lane reads it | posts `release_worker` with that tenure to the reader, which goes on reading and forwarding until it gives the role up |

The reader gives the role up through `Pool.transferReader`, which decides under the mutex and keeps a live worker's reader while the worker has a request in flight. A `release_worker` that arrives after the asking lane's request started therefore changes nothing, and the role moves only while the worker is idle. The next lane to take a slot after the reader let go becomes the reader, so two lanes never read one worker at once.

| `pool.zig:Transfer` | When | The reader (`worker_registration.zig:applyReaderTransfer`) |
| --- | --- | --- |
| `stale` | the tenure already ended, or the worker left the table | stops reading on that tenure's behalf |
| `kept` | the worker is live with a slot held | goes on reading and forwarding |
| `free_held_payloads` | the worker is live and idle, and the reader still holds forwarded ring payloads | frees them in ring order and asks again (`command_flow.zig:giveUpTenure`): every owner gave its slot back, an owner answers before that or never, and the next reader decodes from the ring's read cursor |
| `vacated` | a live idle worker, or one out of service that a lane still holds | cancels its polls on the worker and wakes the reaper to watch the worker's pidfd |
| `retire` | the worker is out of service and this was its last hold | as `vacated`, and queues the retirement |

A handoff whose lane never saw it goes back with its grant (`Pool.returnHandoff`), ending a tenure the grant made, and a refused `release_worker` is forgotten so that the next grant asks again (`Pool.releaseRequestLost`). An entry's epoch keeps counting across the workers it holds and is never 0 (`pool.zig:nextEpoch`).

A worker leaves service through `markDead` (a fault, its exit or its deadline's grace), `retireForEgress` or `retireIdle`, which its entry records as its `Departure`, and no slot of it is handed out afterwards. `Pool.markDead` checks under the mutex that the record still holds the worker key its caller saw, and returns a `Death` that names every lane holding a slot of the worker or reading it, or sets `retire` when none does; only the first caller gets one. The worker is finished once no lane holds or reads it, and exactly one call reports that: `retire` from `release`, `returnHandoff`, `transferReader` or `retireIdle`, or a `Death` with `retire` set. Its caller queues the retirement to the reaper, which calls `Pool.remove` after the teardown so a later launch can reuse the entry.

| `pool.zig:Pool` call | Caller | Answer |
| --- | --- | --- |
| `acquire` | a lane at admission | `.acquired` with a slot and a grant, `.wait`, `.full` |
| `release`, `returnHandoff` | the lane that finishes a request; the lane or launcher whose `dispatch_ready` was refused or never read | `.idle`, `.handed_to` a waiter, `.retire` |
| `cancelWaiter` | a lane whose waiting request ended | whether the waiter was still queued |
| `growthWanted`, `takeStranded` | lanes, the launcher and the metrics thread, and the reaper for `growthWanted` | advisory growth; the waiters left for 503 |
| `launchStarted`, `publish`, `launchEnded` | the launcher thread | a `LaunchTicket`; the handoffs to waiters; the entry back |
| `markDead`, `retireForEgress` | the first thread to see a death; the launcher | a `Death`, or null |
| `transferReader` | the reader lane, or a lane ending a tenure it never took up | `stale`, `kept`, `free_held_payloads`, `vacated`, `retire` |
| `idleWorkers`, `retireIdle`, `remove` | the reaper thread, and for `remove` the exiting thread at shutdown | idle candidates; `not_idle`, `retire`, `release_reader`; the emptied entry |

No pool method takes another lock or calls out, so the pool's mutex is never held across a send, a wait or a callback, and a caller posts the commands a result asks for after the method returns (`service_deps.zig:postToLane`). The visitors of `Pool.findLive` and `Pool.visitWorker` run under the mutex and only touch the record fields it guards or duplicate descriptors.

## The launcher

`launcher.zig:Launcher` is one thread for the node. The zygote serves one fork at a time on one thread, so a single launcher loses no fork throughput, and at most one fork request is outstanding (`Launcher.forking`). The launcher never kills a worker, waits for an exit or removes a cgroup: a failed launch goes to `Deps.failed` with what the child left, and the reaper does the rest. Besides its `poll`, it waits only inside a gateway call, an egress attach or a gateway spawn, and neither runs while a fork request is outstanding, because a thread blocked past a fork reply's deadline fails that fork as `fork_reply_timeout`, which kills the zygote and stops the server.

`Launcher.submit` sets a bit per definition, so submissions coalesce and never fail for room. Each turn of the thread (`launcher.zig:threadMain`) claims launches for every definition submitted or deferred since the last one (`claimSubmitted`), while the launch table has room (`hasRoom`: launches in flight plus failed launches whose leftovers the reaper has not torn down, below `definitions × pool_cold_starts_in_flight_max`), through `Deps.claim` (`Supervisor.claimLaunch`, `Pool.launchStarted`). A definition the table had no room for waits for the next turn. After a publish the launcher claims for the definition again, because the waiters the new worker could not serve submit nothing more.

| `launcher.zig:LaunchState` | Holds | Waits for | Bound |
| --- | --- | --- | --- |
| `queued` | a ticket | its turn at the zygote, the oldest claim first | none |
| `fork_requested` | a send scratch, the egress wake set, the cgroup leaf and the egress session | the fork reply on the zygote's control socket | `fork_reply_timeout_ms`, 5 s |
| `init_sent` | the launch machine (`host/launch.zig:Machine`) | `WorkerReady` on the init socket, or the child's exit on its pidfd | `child_window_ms`, 3 s |
| `awaiting_reattach` | a ready worker whose egress session was lost | a turn with no fork outstanding, to attach it to the current gateway | none |

`launcher.zig:startFork` gets what a fork needs cheapest first, so a launch that cannot get one of them never forks: the worker's 1 MiB send scratch, its egress wake set, a fork job id and the cgroup leaf with the definition's memory limit (`host/cgroup_root.zig:WorkerCgroupRoot.createWorkerDir`), the egress session when the definition has a grant, which every definition has (`worker_factory.zig:definitionHasEgressGrant`, `attachLaunchEgress`), and then the fork request with the leaf (`zygote/host_client.zig:sendForkRequest`). On the reply (`launcher.zig:receiveForkReply`), `host/launch.zig:Machine.start` prepares the child's tmp root, shared pages and channels and sends `WorkerInit`, whose fields and descriptors [boot.md](boot.md#the-servers-side) lists. The child window is fixed at that send, and the boot token minted then carries it as its deadline; the launcher closes its own copies of the session's descriptors once `WorkerInit` went out.

Each turn waits in one `poll` until a source is ready or the earliest deadline of a launch or of the egress side (`launcher.zig:pollTimeoutMs`):

| Entry (`launcher.zig:buildPollSet`) | Polled | Wakes the thread for |
| --- | --- | --- |
| the wake eventfd | always | `submit`, `stop`, `gatewayLost`, `egressSessionLost`, `leftoversReaped` |
| the zygote's pidfd | until it reports the exit | the zygote's exit, which stops the server |
| the zygote's control socket | while a fork request is outstanding | the fork reply |
| a live worker's control socket, for room | while its `egress_attach` waits | the reattach's send |
| each `init_sent` launch's init socket and pidfd | until `WorkerReady` or a failure | `WorkerReady`, an init failure, the child's exit |

A reply or a `WorkerReady` that arrived while the thread was in a gateway call is read before its deadline is judged, and a reply the zygote sent before it died is still read, since its child no longer needs the zygote (`launcher.zig:waitAndHandle`, `handleReady`). A failed `poll` sleeps 10 ms and tries again, and deadlines keep expiring meanwhile (`launcher.zig:poll_retry_ns`).

At `WorkerReady` (`launcher.zig:onReady`) the server's end of the worker's control socket stops blocking, once for the worker's life, because lanes send and read on it from their loops. A launch whose session's gateway was lost, or whose session the gateway removed, waits in `awaiting_reattach`. A launch with a current session sends the gateway its boot token's end, best effort and without waiting, so the gateway may read it after the worker's first request (`server/gateway/manager.zig:Manager.requestEnded`), and publishes; a launch that booted detached publishes with no session, and the reattach pass reaches it. `Deps.publish` (`service_deps.zig:launchPublish`) builds the record (`worker_registry.zig:buildRecord`), publishes it (`Pool.publish`), posts `dispatch_ready` for each handoff (`service_deps.zig:postHandoff`), and wakes the reaper to watch the worker's pidfd when it serves no waiter and so has no reader. Every launch, published or failed, leaves a `LaunchTrace` for the cold-start benchmark and local-e2e (`Launcher.takeTraces`).

A failed launch (`launcher.zig:endFailed`) releases what it holds and hands the child's pidfd and cgroup leaf (`Leftovers`) to `Deps.failed` (`service_deps.zig:launchFailed`), which gives the ticket back (`worker_factory.zig:endLaunch`), answers 503 to the waiters nothing is left to serve (`strandWaiters` with `launch_failed`) and queues the leftovers to the reaper. A failed launch starts no other, so a definition whose boot always fails waits for its next request to try again.

| `launcher.zig:LaunchFailure` | Cause |
| --- | --- |
| `cgroup_leaf`, `egress_wake_set` | the cgroup leaf could not be created or configured, or there is no cgroup root; the wake set or a detached launch's wake descriptors could not be created |
| `zygote_died`, `zygote_protocol`, `fork_refused` | the zygote exited or closed its socket before it replied; its reply or the child's init outcome broke the protocol, or a local step of `Machine.start` failed; it refused this fork and stays up for the next |
| `fork_reply_timeout` | no reply within `fork_reply_timeout_ms`; a late reply would read as the answer to the next request |
| `egress_attach`, `egress_gateway_required` | the gateway refused the session, or a launch whose session was lost before `WorkerReady` was refused a new one or could not be sent it; no gateway is wired or the attachment came back incomplete |
| `worker_cgroup_not_prepared`, `invalid_worker_tmp_root_mode`, `invalid_worker_tmp_root_owner`, `invalid_boot_options` | the launch's own checks of the child's leaf, its tmp root and the boot options (`LaunchFailure.fromLaunchError`) |
| `worker_init_failed`, `child_window_expired` | the child reported an init failure or died before `WorkerReady`, and the launcher's warning names its reason or whether it died for memory ([boot.md](boot.md#a-failed-boot)); it missed its window |
| `control_socket`, `out_of_memory`, `stopping` | the control socket could not be made non-blocking, an allocation failed, the launcher stopped first |

`zygote_died` and `fork_reply_timeout` end the zygote (`LaunchFailure.endsZygote`): no fork request follows, the launcher kills the zygote so that its pidfd reports the exit (`launcher.zig:loseZygote`), and the zygote's exit stops the server, since nothing restarts it.

A gateway loss (`Launcher.gatewayLost`) starts a pass on the launcher thread: a gateway spawn at most once per `egress_prewarm_interval_ms`, then, one per turn, each live worker whose session is not of the current gateway (`Supervisor.nextStaleEgressWorker`). The worker gets a new session on its wake set, its record takes the session first, so that no token minted after the attach names the old one (`Supervisor.setWorkerEgress`), and then its control socket gets the session's worker half as an `egress_attach` packet, waiting up to `egress_attach_send_timeout_ms` for room. The gateway's refusal of the session, or a control socket that refuses the packet or takes nothing in time, retires the worker (`Deps.retireForEgress`, announced as `egress_session_failed`); an attach error of any other kind, or descriptors the server could not duplicate, leaves the worker detached on its old session and starts the pass over (`launcher.zig:reattachNextStale`, `trySendEgressAttach`). A session the gateway removed on its own (`Launcher.egressSessionLost`) takes its worker's record off the session and starts the pass over (`Supervisor.dropEgressSession`). While the pass waits for a gateway, a launch boots detached. A launch whose session was lost by `WorkerReady` attaches to the current gateway before it publishes; it publishes detached when no gateway is current or the attach fails for any reason but a refusal, and fails with `egress_attach` on a refusal or a failed send (`launcher.zig:reattachReady`).

## The reaper

`reaper/root.zig:Reaper` is the node's one thread that retires workers: every worker that leaves its pool is torn down there, off the request path, and so is the child and leaf of a failed launch. Work arrives three ways. The thread whose pool call answered `retire` queues the worker (`Reaper.queueRetirement`, through `service_deps.zig:queueRetirement`, which passes the departure); the launcher queues a failed launch's leftovers (`Reaper.queueLeftovers`); and the reaper runs its own passes and watches pidfds. The retire queue holds one entry per record and one per launch-table entry, so it never fills: a pool reports each finished worker once and keeps its entry until `remove`, and the launcher counts the leftovers it handed over until the reaper reports them torn down (`Launcher.leftoversReaped`).

Each turn rescans the workers to watch (`reaper/root.zig:scanReaderless`), waits in one `poll` until a source is ready or the next periodic pass is due, every 5 s by default (`reaper/reaping.zig:default_interval_ns`), handles what is ready, runs the passes when PSI fired or the interval is up, and carries out the queued retirements (`reaper/root.zig:processQueue`).

| Entry (`reaper/root.zig:buildPollSet`) | Wakes the reaper for |
| --- | --- |
| the wake eventfd | a queued retirement or leftovers, a pidfd rescan, stop |
| the demand-reclaim eventfd (`Supervisor.demand_reclaim_eventfd`) | a launcher claim at or above the high water, or one the memory gate refused (`Supervisor.nudgeDemandReclaim`) |
| the PSI trigger on `/proc/pressure/memory`, for POLLPRI | memory stalls past `psi_some_trigger`; when a kernel without PSI refuses the trigger, as one before Linux 6.4 does without `CAP_SYS_RESOURCE`, or the trigger reports an error, only the interval pass and demand reclaim read pressure ([memory-pressure.md](memory-pressure.md#the-node)) |
| the pidfd of each live idle worker no lane reads | that worker's exit |

The periodic pass reads node memory, caches it for the memory gate, runs the idle pass, then the plan the pressure calls for (`reaper/root.zig:runPasses`). A reading that fails never reads as calm: it stands on the last reading that succeeded, 0% included, or reads as critical before the first and whenever the read failed for want of memory (`reaper/memory.zig:LastReading`, `readPressure`). Node memory is the usage of the server's own cgroup against its limit, or the machine's when that cgroup has no limit or cannot be read, so always the machine's in the delegated placement, whose `<own>/main` has no limit ([memory-pressure.md](memory-pressure.md#the-node)). The idle pass first posts `release_worker` again to each reader that still holds a worker retiring idle (`retryReleases`), then retires the workers idle past `worker_idle_ttl_ns`, 10 min by default and 0 to turn the pass off, within `sweep_budget_ns` and `sweep_cap_max` (`reaper/reaping.zig:idleTtlPass`). Demand reclaim runs when a launcher claim wakes it and memory is at soft pressure or above (`reaper/root.zig:demandPass`).

| Pressure (`reaper/memory.zig:memoryPressureFromUsedPercent`) | Used memory | Plan (`reaper/reaping.zig:memoryPressurePlan`) |
| --- | --- | --- |
| none | below 70 % | nothing, and the soft clock resets |
| soft | from 70 % | nothing for 30 s; then workers idle 10 min, 5 %, at most 4; after 10 s, idle 5 min, 5 %, at most 4; after 10 s more, idle 3 min, 10 %, at most 8 |
| hard | from 85 % | workers idle 3 min, 25 %, at most 8 |
| critical | from 92 % | any idle worker, 50 %, at most 16 |
| demand reclaim | soft or above, woken by a claim | any idle worker, 25 %, at most 4 (`reaper/reaping.zig:demand_plan`) |

A reap (`reaper/reaping.zig:reapWithPlan`) keeps the best candidates by score, up to the plan's cap. The score is the worker's private resident bytes from `smaps_rollup`, which leaves out the pages it still shares with the zygote, or its cgroup's `memory.current` when those cannot be read, weighted by idle age as a fraction of the idle TTL, clamped to 50 through 1000 thousandths (`reaper/memory.zig:workerMemoryVictimScoreWithUnknownFallback`). The reap retires the plan's percentage of the candidates, rounded up, at least one and at most the cap (`memoryPressureReapBudget`), and reads memory again after each retirement, stopping once usage falls below the high water. Only idle workers are candidates (`Pool.idleWorkers`), and each is asked again before it goes (`Reaper.retireIdleWorker`, `Pool.retireIdle`): a worker no lane reads is torn down at once, and a worker with a reader gets `release_worker` posted to that reader, whose `transferReader` answers `retire` and queues the retirement.

A retirement (`reaper/root.zig:retire`) checks with the pool that the worker is out of service with no holder and no reader, logs the cgroup's CPU time of a worker that died (`usage_drain.zig:noteWorkerDeathBurn`), and tears it down (`worker_registry.zig:teardown`): SIGKILL through the pidfd, a wait for the exit up to `PROCESS_EXIT_WAIT_MS`, the final drains of its usage and console rings (`usage_drain.zig:drainFinal`), then `Record.vacate`, whose handle teardown closes the worker's descriptors, unmaps its page and payload rings, deletes its tmp root and removes its cgroup leaf with retries. `Pool.remove` then frees the entry, and the reaper submits a launch with reason `capacity` when the pool wants one. The worker's egress session needs nothing, because the exit hangs up the liveness pipe its gateway watches. At shutdown the service stops the reaper last and carries out what its queue still holds on the exiting thread (`Reaper.drainRetirements`).

## Death detection

| Seen by | How | What follows |
| --- | --- | --- |
| the worker's reader lane | its pidfd (`exited`), a hang-up of its control or fault socket (`peer_closed`), a fault in its output | the death path (`worker_fault.zig:faultWorker`): `Pool.markDead`, the last of the output when the reason leaves it trusted, `worker_died` to the other lanes the `Death` names, and the lane's own requests ended |
| a lane holding a request on the worker | a failed send, a forwarded descriptor that shows a fault, the grace backstop (`deadline_grace_expired`) | the same path, through the lane's registration of the worker |
| a lane with no registration of the worker | a descriptor the worker's reader forwarded that names no request of this lane on that worker | `Pool.markDead`, which checks that the record still holds the worker's key, then `worker_died` to the lanes the `Death` names and a replacement (`worker_fault.zig:faultWorkerSeenElsewhere`) |
| the reaper | the pidfd of a live idle worker no lane reads (`reaper/root.zig:workerExited`) | `Pool.markDead`, `worker_died` with `exited` to the lanes it names, the retirement at once when it names none |
| the metrics thread | a usage ring whose head no append puts there (`usage_record_protocol`), a console ring that contradicts itself (`log_ring_corrupt`) | `Pool.markDead` under the record's `metrics_mutex`, then `service_deps.zig:announceWorkerDeath` (`analytics_drain.zig`) |
| the launcher | a reattach the gateway refused or the worker's socket did not take (`egress_session_failed`) | `Pool.retireForEgress`, announced the same way (`service_deps.zig:launchRetireForEgress`) |
| the launcher | the zygote's pidfd | the server stops (`service_deps.zig:launchZygoteExited`) |

A worker's pidfd is always watched: by its reader for the whole tenure, which an idle worker keeps, and by the reaper while the worker is live, idle and has no reader; a lane that gives the role up wakes the reaper to rescan (`Reaper.wakeForPidfdScan`). The first `markDead` owns the death and every later one gets null, so each lane ends its requests on the worker once, with the reason it recorded first (`completions.zig:Registration.fault`). A worker that exited or hung up counts as `memory` when its page says its sentinel ended it for memory or its cgroup counted an `oom_kill`, and as `crash` otherwise (`usage_drain.zig:classifyWorkerDeath`). A lane that owns a death, and `service_deps.zig:announceWorkerDeath` for the metrics thread and the launcher, then ask for a replacement or answer 503 to the waiters nothing can serve; the reaper submits one after the retirement frees the entry.

## Caps

| Cap | Value | File | Bounds |
| --- | --- | --- | --- |
| `pool_workers_max` | 16 | `scheduler_limits.zig:capacity` | table entries per pool, so the live, retiring, dead and launching workers of one definition; with it the records per definition, the reaper's queue and watch list, and one lane's registrations (`runner/root.zig:max_completion_registrations`); the memory gate is the real ceiling |
| `pool_cold_starts_in_flight_max` | 2 | `scheduler_limits.zig:capacity` | launches one pool has in flight, which sizes the launcher's table at two per definition and keeps a burst on one definition from queueing every other definition's launches behind its own |
| `pool_waiters_max` | 256 | `common/limits/pool.zig` | requests one pool queues before it answers 503, and the scan a waiter's cancel makes under the mutex |
| `slots_per_worker_max` | 2 | `pool.zig`, from `common/limits/server.zig:worker_concurrency_max` | slots per worker, which are the live request slots of its shared page, and so every definition's `concurrency` |
| `entries_max` | 255 | `pool.zig` | the entries a launch ticket's byte can name |
| `autoscale_high_water_percent` | 70 | `scheduler_limits.zig:memory` | where soft pressure starts; a claimed launch at or above it wakes demand reclaim, and a reap stops once usage falls below it |
| `reclaim_low_water_percent` | 65 | `scheduler_limits.zig:memory` | where a reap would stop; usage falling from above crosses 70 first, so it decides nothing (a FIXME in the file) |
| `evict_before_fork_percent` | 85 | `scheduler_limits.zig:memory` | where hard pressure starts; no code evicts before a fork at this level (a FIXME in the file) |
| `fork_deny_percent` | 92 | `scheduler_limits.zig:memory` | where the memory gate closes and critical pressure starts |
| `psi_stall_us`, `psi_window_us` | 300 ms of stall in 2 s | `scheduler_limits.zig:memory` | when the PSI trigger (`psi_some_trigger`) wakes the reaper; 2 s is the shortest window a process without `CAP_SYS_RESOURCE` may arm |
| `soft_sustain_ns`, `soft_stage_ns` | 30 s, 10 s | `scheduler_limits.zig:memory` | how long soft pressure lasts before its first stage, and between stages |
| `soft_stage_0_idle_ns`, `soft_stage_1_idle_ns`, `soft_stage_2_idle_ns` | 10, 5, 3 min | `scheduler_limits.zig:memory` | the idle floor of each soft stage; hard pressure uses the last |
| `reap_cap_max` | 16 | `scheduler_limits.zig:memory` | workers one pressure reap retires, and the size of its victim set |
| `sweep_budget_ns`, `sweep_cap_max` | 500 ms, 256 | `scheduler_limits.zig:memory` | the time and the retirements of one idle-TTL sweep, which pays each teardown on the reaper thread |

| Time | Value | Bounds |
| --- | --- | --- |
| `reaper/reaping.zig:default_interval_ns` | 5 s | the time between the reaper's periodic passes |
| `supervisor.zig:default_worker_idle_ttl_ns` | 10 min | how long a worker stays idle before the TTL pass retires it |
| `launcher.zig:fork_reply_timeout_ms` | 5 s | the wait for a fork reply; a miss kills the zygote |
| `launcher.zig:child_window_ms` | 3 s | `WorkerInit` to `WorkerReady` |
| `launcher.zig:egress_attach_send_timeout_ms` | 1 s | the wait for room for a live worker's `egress_attach` |
| `launcher.zig:egress_prewarm_interval_ms` | 1 s | the time between gateway spawns, and between reattach passes |
| `common/limits/process.zig:PROCESS_EXIT_WAIT_MS` | 1 s | a teardown's wait for the worker's exit |
| `launcher.zig:lost_sessions_max`, `trace_capacity` | 512, 256 | session-loss reports waiting for the launcher thread, finished launches kept for `takeTraces` |
