// Monotonic module-scope cache. One entry is inserted per call (keyed by the
// global call counter), so private heap grows ~linearly with call_count until
// the LRU cap is hit and it plateaus. This is the workload that makes the
// 1 -> 100 -> 10000 axis actually move: every other workload is steady-state.
const __CACHE = new Map();
const __CACHE_CAP = 4096;
const __CACHE_TAGS = ["gru", "iad", "fra", "sin", "cdg", "nrt"];

function __cacheValue(id) {
    return {
        id: id,
        token: "sess-" + (id >>> 0).toString(36) + "-" + (((id * 2654435761) >>> 8) >>> 0).toString(36),
        weight: (id * 31) | 0,
        tag: __CACHE_TAGS[id % __CACHE_TAGS.length],
        seen: 1,
    };
}

function workloadKernel(iterations) {
    const base = __totalCalls | 0;
    const key = "k:" + base;
    let entry = __CACHE.get(key);
    if (entry === undefined) {
        entry = __cacheValue(base);
        __CACHE.set(key, entry);
        if (__CACHE.size > __CACHE_CAP) {
            const oldest = __CACHE.keys().next().value;
            __CACHE.delete(oldest);
        }
    } else {
        entry.seen = (entry.seen + 1) | 0;
    }

    let digest = entry.weight | 0;
    for (let i = 0; i < iterations; i++) {
        const probe = "k:" + (base - (i % 64));
        const hit = __CACHE.get(probe);
        if (hit !== undefined) {
            digest = (Math.imul(digest ^ hit.weight, 16777619) ^ hit.token.length) | 0;
        } else {
            digest = (digest ^ 0x9e3779b9) | 0;
        }
    }
    return digest >>> 0;
}
