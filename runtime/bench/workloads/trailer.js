function runOneCall(iterations) {
    __acc = ((__acc * 31) ^ workloadKernel(iterations)) | 0;
    __lastDigest = __acc >>> 0;
    __totalCalls++;
    return __totalCalls;
}

function readLastDigest() {
    return (__lastDigest ^ __totalCalls ^ 0x9e3779b9) >>> 0;
}

export default function runBench() {
    for (let i = 0; i < __COLLO_CALLS; i++) {
        runOneCall(__COLLO_ITERATIONS);
    }
    return String(readLastDigest());
}
