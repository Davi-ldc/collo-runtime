def stats:
  sort as $values |
  ($values | length) as $n |
  if $n == 0 then error("empty metric") else
    {samples:$n, min:$values[0],
     median:(if ($n % 2) == 1 then $values[($n/2|floor)]
             else ($values[$n/2-1]+$values[$n/2])/2 end),
     p95:$values[(($n*0.95|ceil)-1)], max:$values[-1]}
  end;
def mib: . / 1048576;
. as $rows |
[$rows[] | select(.kind == "cold_sample")] as $cold |
[$rows[] | select(.kind == "memory_sample")] as $memory |
[$rows[] | select(.kind == "process_memory" and .role == "sandbox")] as $processes |
[$rows[] | select(.kind == "process_memory")] as $all_processes |
# Sums over every runtime process read at one moment of one insertion. PSS and
# private bytes are additive across processes, unlike RSS or shared bytes.
def process_sums($sample; $moment):
  [$all_processes[] | select(.scope == $sample.scope and .phase == $sample.phase and
                             .cycle == $sample.cycle and .moment == $moment)] |
  {count:length, pss:(map(.memory.pss_bytes)|add),
   private_dirty:(map(.memory.private_dirty_bytes)|add), uss:(map(.uss_bytes)|add)};
def process_sum_marginal:
  map(. as $sample | process_sums($sample; "before") as $before |
      process_sums($sample; $sample.phase) as $after |
      if $before.count == 0 then null
      elif $after.count != $before.count + 1 then error("process set does not pair")
      else {pss:(($after.pss - $before.pss)|mib),
            private_dirty:(($after.private_dirty - $before.private_dirty)|mib),
            uss:(($after.uss - $before.uss)|mib)} end) |
  if any(. == null) then null
  else {pss_mib:(map(.pss)|stats), private_dirty_mib:(map(.private_dirty)|stats),
        uss_mib:(map(.uss)|stats)} end;
{
  schema:"collo.microbench.summary.v1",
  metadata:[$rows[] | select(.kind == "metadata")],
  cold_ms:(if ($cold|length) == 0 then null else {
    samples:($cold|length),
    creation:($cold|map(.durations.creation_ns/1000000)|stats),
    dispatch:($cold|map(.durations.dispatch_ns/1000000)|stats),
    total:($cold|map(.durations.total_ns/1000000)|stats)
  } end),
  memory:($memory | group_by([.phase,.population_before,.cycle]) | map(
    . as $group | {
      phase:.[0].phase,
      population_before:.[0].population_before,
      population_after:.[0].population_after,
      cycle:.[0].cycle,
      marginal_mib:(map(.marginal_bytes|mib)|stats),
      amortized_mib:(map(.amortized_bytes|mib)|stats),
      creation_peak_added_mib:(map(.creation_peak_added_bytes|mib)|stats),
      paired_load_growth_mib:(map(.load_growth_bytes|mib)|stats),
      total_cgroup_mib:(map(.after.snapshot.current_bytes|mib)|stats),
      process_sum_marginal:process_sum_marginal,
      target_process:([
        $group[] as $sample |
        $processes[] |
        select(.scope == $sample.scope and .phase == $sample.phase and
               .cycle == $sample.cycle and .moment == $sample.phase and
               .worker.worker_id == $sample.worker.worker_id and
               .worker.worker_generation == $sample.worker.worker_generation and
               .pid == $sample.worker.pid)
      ] | {
        rss_mib:(map(.memory.rss_bytes|mib)|stats),
        pss_mib:(map(.memory.pss_bytes|mib)|stats),
        shared_mib:(map(.shared_mapped_bytes|mib)|stats),
        private_mib:(map(.uss_bytes|mib)|stats)
      })
    }
  )),
  teardown:([$rows[] | select(.kind == "memory_teardown")]
    | group_by([.phase,.population,.cycle]) | map({
        phase:.[0].phase, population:.[0].population, cycle:.[0].cycle,
        retained_mib:(map(.retained_bytes|mib)|stats)
      }))
}
