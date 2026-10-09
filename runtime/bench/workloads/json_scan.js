const __JSON_PAYLOADS = [
    "{\"method\":\"GET\",\"path\":\"/api/users/102/orders/7\",\"tenant\":\"acme\",\"flags\":[1,0,1],\"body\":{\"q\":\"warm\"}}",
    "{\"method\":\"POST\",\"path\":\"/api/projects/22/deploy\",\"tenant\":\"beta\",\"flags\":[0,1,1],\"body\":{\"size\":4096}}",
    "{\"method\":\"PATCH\",\"path\":\"/api/users/77/profile\",\"tenant\":\"acme\",\"flags\":[1,1,0],\"body\":{\"name\":\"Davi\"}}",
    "{\"method\":\"GET\",\"path\":\"/assets/app.js\",\"tenant\":\"static\",\"flags\":[0,0,1],\"body\":{\"etag\":\"abc123\"}}",
];

function workloadKernel(iterations) {
    let digest = 0;
    for (let i = 0; i < iterations; i++) {
        const s = __JSON_PAYLOADS[(i + __totalCalls) & 3];
        let hash = 0x811c9dc5 | 0;
        let depth = 0;
        let colon = 0;
        let slash = 0;
        let quote = 0;
        for (let j = 0; j < s.length; j++) {
            const c = s.charCodeAt(j);
            hash = Math.imul(hash ^ c, 16777619) | 0;
            if (c === 123 || c === 91) depth++;
            else if (c === 125 || c === 93) depth--;
            else if (c === 58) colon++;
            else if (c === 47) slash++;
            else if (c === 34) quote ^= 1;
        }
        digest = (digest ^ hash ^ Math.imul(colon + 1, 97) ^
            Math.imul(slash + 1, 193) ^ depth ^ quote) | 0;
    }

    return digest | 0;
}

