// Builds objects with many distinct hidden classes (Structures). The property
// subset is chosen by a varying bitmask, and an occasional delete forks the
// transition table further. Distinct shapes accumulate up to ~2^keys, so the
// JSC Structure table -- nearly immortal, hence private after fork -- grows
// with call_count then plateaus. This is exactly what the warmup corpus is
// meant to pre-bake; the workload measures the ceiling of what can be shared.
const __SHAPE_KEYS = [
    "id", "name", "plan", "score", "active", "region",
    "tier", "ts", "ref", "flags", "seat", "trace",
];

function __buildShaped(mask, n) {
    const o = {};
    for (let b = 0; b < __SHAPE_KEYS.length; b++) {
        if (mask & (1 << b)) o[__SHAPE_KEYS[b]] = (n + b) | 0;
    }
    if ((mask & 1) && (n & 3) === 0 && ("name" in o)) delete o.name;
    return o;
}

function __countProps(o) {
    let c = 0;
    for (const _k in o) c++;
    return c;
}

function workloadKernel(iterations) {
    let digest = 0;
    for (let i = 0; i < iterations; i++) {
        const mask = (((i + __totalCalls) * 2654435761) >>> 20) & 0xfff;
        const o = __buildShaped(mask, i);
        const score = (o.score === undefined) ? 0 : (o.score | 0);
        digest = (Math.imul(digest ^ __countProps(o), 16777619) ^ score) | 0;
    }
    return digest >>> 0;
}
