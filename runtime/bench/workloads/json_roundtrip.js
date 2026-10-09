// Real JSON.parse + JSON.stringify per iteration (the actual JSON fast path,
// not the manual char scan in json_scan). Each call builds a fresh object
// graph + ropes and drops it, so this stresses per-call allocation, structure
// materialization for the parsed shapes, and GC churn -- the realistic handler.
const __JSON_TEMPLATES = [
    '{"method":"POST","path":"/api/projects/PID/deploy","tenant":"acme","headers":{"x-region":"gru","x-trace":"TRC"},"body":{"size":SIZE,"flags":[true,false,true],"items":[{"k":"a","v":1},{"k":"b","v":2},{"k":"c","v":3}]}}',
    '{"method":"GET","path":"/api/users/UID/orders","tenant":"beta","headers":{"accept":"application/json"},"body":null,"page":{"cursor":"CUR","limit":50}}',
    '{"event":"signup","id":IDV,"props":{"plan":"pro","seats":7,"meta":{"ref":"REF","utm":["x","y","z"]}},"ts":TSV}',
];

function __fillTemplate(t, n) {
    return t
        .replace("PID", "" + (n % 1000))
        .replace("UID", "" + (n % 5000))
        .replace("SIZE", "" + ((n * 17) & 0xffff))
        .replace("TRC", (n >>> 0).toString(16))
        .replace("CUR", (((n * 2654435761) >>> 8) >>> 0).toString(36))
        .replace("IDV", "" + n)
        .replace("REF", "r" + (n % 97))
        .replace("TSV", "" + (1700000000 + n));
}

function __sumGraph(o) {
    if (o === null || o === undefined) return 0;
    const t = typeof o;
    if (t === "number") return o | 0;
    if (t === "string") return o.length;
    if (t === "boolean") return o ? 1 : 0;
    let s = 0;
    if (Array.isArray(o)) {
        for (let i = 0; i < o.length; i++) s = (s + __sumGraph(o[i])) | 0;
        return s;
    }
    for (const k in o) s = (s + k.length + __sumGraph(o[k])) | 0;
    return s;
}

function workloadKernel(iterations) {
    let digest = 0;
    for (let i = 0; i < iterations; i++) {
        const n = (i + Math.imul(__totalCalls, iterations)) | 0;
        const text = __fillTemplate(__JSON_TEMPLATES[n % __JSON_TEMPLATES.length], n >>> 0);
        const parsed = JSON.parse(text);
        const walked = __sumGraph(parsed);
        const round = JSON.stringify(parsed);
        digest = (Math.imul(digest ^ walked, 16777619) ^ round.length) | 0;
    }
    return digest >>> 0;
}
