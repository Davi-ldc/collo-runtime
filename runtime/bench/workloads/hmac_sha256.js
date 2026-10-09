const __shaK = new Int32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);
const __shaW = new Int32Array(64);
const __HMAC_IPAD = new Int32Array([
    0x7b736207, 0x57567606, 0x7363527b, 0x7e524376,
    0x6e605b53, 0x40424d77, 0x6c52535d, 0x60564042,
    0x36363636, 0x36363636, 0x36363636, 0x36363636,
    0x36363636, 0x36363636, 0x36363636, 0x36363636,
]);
const __HMAC_OPAD = new Int32Array([
    0x1119086d, 0x3d3c1c6c, 0x1909380a, 0x14380a1c,
    0x040a3139, 0x2a282709, 0x06383933, 0x0a3c2a28,
    0x5c5c5c5c, 0x5c5c5c5c, 0x5c5c5c5c, 0x5c5c5c5c,
    0x5c5c5c5c, 0x5c5c5c5c, 0x5c5c5c5c, 0x5c5c5c5c,
]);
const __JWT_BLOCK0 = new Int32Array([
    0x65794a68, 0x62476369, 0x4f694a49, 0x55794932,
    0x4e694973, 0x496e5235, 0x63434936, 0x496b7058,
    0x56434a39, 0x2e65794a, 0x7a645749, 0x694f6949,
    0x784d6a4d, 0x304e5459, 0x3349704c, 0x434a7562,
]);
const __JWT_BLOCK1 = new Int32Array([
    0x434a3169, 0x6261673a, 0x57702369, 0x3349564a,
    0x434a7864, 0x436c5959, 0x80000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000578,
]);
const __INNER_PAD = new Int32Array(16);
const __HMAC_HI = new Int32Array(4);
const __HMAC_LO = new Int32Array(4);

function __shaCompress(stateHi, stateLo, block, blockOff) {
    for (let i = 0; i < 16; i++) {
        __shaW[i] = block[blockOff + i] | 0;
    }
    for (let i = 16; i < 64; i++) {
        const w15 = __shaW[i - 15];
        const w2 = __shaW[i - 2];
        const s0 = (rotr32(w15, 7) ^ rotr32(w15, 18) ^ (w15 >>> 3)) | 0;
        const s1 = (rotr32(w2, 17) ^ rotr32(w2, 19) ^ (w2 >>> 10)) | 0;
        __shaW[i] = (__shaW[i - 16] + s0 + __shaW[i - 7] + s1) | 0;
    }

    let a = stateHi[0], b = stateHi[1], c = stateHi[2], d = stateHi[3];
    let e = stateLo[0], f = stateLo[1], g = stateLo[2], h = stateLo[3];
    for (let i = 0; i < 64; i++) {
        const s1 = (rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)) | 0;
        const ch = ((e & f) ^ (~e & g)) | 0;
        const t1 = (h + s1 + ch + __shaK[i] + __shaW[i]) | 0;
        const s0 = (rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)) | 0;
        const maj = ((a & b) ^ (a & c) ^ (b & c)) | 0;
        const t2 = (s0 + maj) | 0;
        h = g; g = f; f = e; e = (d + t1) | 0;
        d = c; c = b; b = a; a = (t1 + t2) | 0;
    }
    stateHi[0] = (stateHi[0] + a) | 0;
    stateHi[1] = (stateHi[1] + b) | 0;
    stateHi[2] = (stateHi[2] + c) | 0;
    stateHi[3] = (stateHi[3] + d) | 0;
    stateLo[0] = (stateLo[0] + e) | 0;
    stateLo[1] = (stateLo[1] + f) | 0;
    stateLo[2] = (stateLo[2] + g) | 0;
    stateLo[3] = (stateLo[3] + h) | 0;
}

function workloadKernel(iterations) {
    let digest = 0;
    const hmacs = (iterations / 5) | 0;
    for (let n = 0; n < hmacs; n++) {
        __HMAC_HI[0] = 0x6a09e667 | 0; __HMAC_HI[1] = 0xbb67ae85 | 0;
        __HMAC_HI[2] = 0x3c6ef372 | 0; __HMAC_HI[3] = 0xa54ff53a | 0;
        __HMAC_LO[0] = 0x510e527f | 0; __HMAC_LO[1] = 0x9b05688c | 0;
        __HMAC_LO[2] = 0x1f83d9ab | 0; __HMAC_LO[3] = 0x5be0cd19 | 0;
        __shaCompress(__HMAC_HI, __HMAC_LO, __HMAC_IPAD, 0);
        __shaCompress(__HMAC_HI, __HMAC_LO, __JWT_BLOCK0, 0);
        __shaCompress(__HMAC_HI, __HMAC_LO, __JWT_BLOCK1, 0);

        __INNER_PAD[0] = __HMAC_HI[0]; __INNER_PAD[1] = __HMAC_HI[1];
        __INNER_PAD[2] = __HMAC_HI[2]; __INNER_PAD[3] = __HMAC_HI[3];
        __INNER_PAD[4] = __HMAC_LO[0]; __INNER_PAD[5] = __HMAC_LO[1];
        __INNER_PAD[6] = __HMAC_LO[2]; __INNER_PAD[7] = __HMAC_LO[3];
        __INNER_PAD[8] = 0x80000000 | 0;
        __INNER_PAD[15] = 768;

        __HMAC_HI[0] = 0x6a09e667 | 0; __HMAC_HI[1] = 0xbb67ae85 | 0;
        __HMAC_HI[2] = 0x3c6ef372 | 0; __HMAC_HI[3] = 0xa54ff53a | 0;
        __HMAC_LO[0] = 0x510e527f | 0; __HMAC_LO[1] = 0x9b05688c | 0;
        __HMAC_LO[2] = 0x1f83d9ab | 0; __HMAC_LO[3] = 0x5be0cd19 | 0;
        __shaCompress(__HMAC_HI, __HMAC_LO, __HMAC_OPAD, 0);
        __shaCompress(__HMAC_HI, __HMAC_LO, __INNER_PAD, 0);

        digest = ((digest * 31) ^ __HMAC_HI[0] ^ __HMAC_LO[3]) | 0;
    }

    return digest >>> 0;
}
