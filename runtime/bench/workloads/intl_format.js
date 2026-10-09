// Worker that uses Intl on the hot path with the DEFAULT locale, matching the
// neutral construction in the zygote warmIntl corpus. With warmIntl present,
// the Intl structures (LazyProperty / LazyClassStructure) are inherited
// CoW-shared from the zygote; without it, each worker re-materializes them
// privately. Comparing this workload's private_dirty / CoW retention with vs
// without warmup isolates the warmIntl sharing win.
const __INTL_NF = (typeof Intl === "object" && Intl && typeof Intl.NumberFormat === "function")
    ? new Intl.NumberFormat()
    : null;
const __INTL_DT = (typeof Intl === "object" && Intl && typeof Intl.DateTimeFormat === "function")
    ? new Intl.DateTimeFormat()
    : null;

function workloadKernel(iterations) {
    let digest = 0;
    for (let i = 0; i < iterations; i++) {
        const n = (i + __totalCalls) | 0;
        if (__INTL_NF !== null) {
            const s = __INTL_NF.format(n * 1234.5);
            digest = (Math.imul(digest ^ s.length, 16777619)) | 0;
        }
        if (__INTL_DT !== null) {
            const d = __INTL_DT.format((n * 86400000) >>> 0);
            digest = (digest ^ d.length) | 0;
        }
    }
    return digest >>> 0;
}
