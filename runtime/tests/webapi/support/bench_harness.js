const __colloWebApiBenches = [];

function bench(name, fn, options = {}) {
  __colloWebApiBenches.push({
    name,
    fn,
    iterations: options.iterations || 10000,
    warmup: options.warmup || 1000,
  });
}

function __colloBenchNowMs() {
  const perf = globalThis.performance;
  if (perf && typeof perf.now === "function")
    return perf.now();
  return Date.now();
}

function __colloBenchRunLoop(fn, iterations, context) {
  const value = fn(iterations, context);
  if (value && typeof value.then === "function")
    return value;
  return value;
}

function __colloBenchRunCount(context) {
  const configured = Number(
    context.runs ?? globalThis.__colloBenchRuns ?? 3,
  );
  if (!Number.isFinite(configured))
    return 3;
  return Math.max(1, Math.trunc(configured));
}

function __colloBenchMean(values) {
  let sum = 0;
  for (const value of values)
    sum += value;
  return sum / values.length;
}

function __colloBenchStddev(values, mean) {
  if (values.length <= 1)
    return 0;
  let sumSquares = 0;
  for (const value of values) {
    const delta = value - mean;
    sumSquares += delta * delta;
  }
  return Math.sqrt(sumSquares / values.length);
}

async function __colloRunWebApiBenchmarks(context = {}) {
  const results = [];
  const runCount = __colloBenchRunCount(context);
  for (const entry of __colloWebApiBenches) {
    await __colloBenchRunLoop(entry.fn, entry.warmup, context);

    const runs = [];
    const nsPerOpValues = [];
    for (let index = 0; index < runCount; index++) {
      const start = __colloBenchNowMs();
      const checksum = await __colloBenchRunLoop(entry.fn, entry.iterations, context);
      const elapsedMs = Math.max(__colloBenchNowMs() - start, 0.001);
      const nsPerOp = (elapsedMs * 1_000_000) / entry.iterations;
      nsPerOpValues.push(nsPerOp);
      runs.push({
        index,
        elapsed_ms: elapsedMs,
        ns_per_op: nsPerOp,
        ops_per_second: 1_000_000_000 / nsPerOp,
        checksum: checksum == null ? null : String(checksum),
      });
    }

    const meanNsPerOp = __colloBenchMean(nsPerOpValues);
    const minNsPerOp = Math.min(...nsPerOpValues);
    const maxNsPerOp = Math.max(...nsPerOpValues);
    const stddevNsPerOp = __colloBenchStddev(nsPerOpValues, meanNsPerOp);
    const relativeStddevPct =
      meanNsPerOp === 0 ? 0 : (stddevNsPerOp / meanNsPerOp) * 100;
    const spreadPct =
      meanNsPerOp === 0 ? 0 : ((maxNsPerOp - minNsPerOp) / meanNsPerOp) * 100;
    const firstChecksum = runs[0]?.checksum ?? null;
    const checksumStable = runs.every((run) => run.checksum === firstChecksum);

    results.push({
      name: entry.name,
      iterations: entry.iterations,
      run_count: runCount,
      runs,
      elapsed_ms: __colloBenchMean(runs.map((run) => run.elapsed_ms)),
      ns_per_op: meanNsPerOp,
      mean_ns_per_op: meanNsPerOp,
      min_ns_per_op: minNsPerOp,
      max_ns_per_op: maxNsPerOp,
      stddev_ns_per_op: stddevNsPerOp,
      relative_stddev_pct: relativeStddevPct,
      spread_pct: spreadPct,
      ops_per_second: 1_000_000_000 / meanNsPerOp,
      checksum: firstChecksum,
      checksum_stable: checksumStable,
    });
  }

  return {
    ok: true,
    runtime: context.runtime || "unknown",
    run_count: runCount,
    total: results.length,
    results,
  };
}
