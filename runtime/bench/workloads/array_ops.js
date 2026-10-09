const __ROWS = (function() {
    const rows = [];
    const tiers = ["bronze", "silver", "gold", "platinum"];
    const regions = ["gru", "iad", "fra", "sin"];
    for (let i = 0; i < 50; i++) {
        rows.push({
            id: 10000 + i,
            score: ((i * 17) ^ 0x5a5a) | 0,
            tier: tiers[i & 3],
            region: regions[(i >>> 1) & 3],
            active: (i & 1) === 0,
        });
    }
    return rows;
})();

function workloadKernel(iterations) {
    let total = 0;
    for (let n = 0; n < iterations; n++) {
        const threshold = ((n + __totalCalls) & 31) | 0;
        const sum = __ROWS
            .filter((row) => row.active && row.score > threshold)
            .map((row) => ({ id: row.id, label: row.tier, weight: (row.score * 2) | 0 }))
            .reduce((acc, row) => (acc + row.weight) | 0, 0);
        total = (total + sum) | 0;
    }

    return total >>> 0;
}

