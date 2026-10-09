function workloadKernel(iterations) {
    let x0 = 0x61707865 | 0, x1 = 0x3320646e | 0, x2 = 0x79622d32 | 0, x3 = 0x6b206574 | 0;
    let x4 = 0x03020100 | 0, x5 = 0x07060504 | 0, x6 = 0x0b0a0908 | 0, x7 = 0x0f0e0d0c | 0;
    let x8 = 0x13121110 | 0, x9 = 0x17161514 | 0, x10 = 0x1b1a1918 | 0, x11 = 0x1f1e1d1c | 0;
    let x12 = 0 | 0, x13 = 0 | 0, x14 = 0 | 0, x15 = 0 | 0;

    for (let i = 0; i < iterations; i++) {
        x0 = (x0 + x4) | 0; x12 = rotl32(x12 ^ x0, 16);
        x8 = (x8 + x12) | 0; x4 = rotl32(x4 ^ x8, 12);
        x0 = (x0 + x4) | 0; x12 = rotl32(x12 ^ x0, 8);
        x8 = (x8 + x12) | 0; x4 = rotl32(x4 ^ x8, 7);

        x1 = (x1 + x5) | 0; x13 = rotl32(x13 ^ x1, 16);
        x9 = (x9 + x13) | 0; x5 = rotl32(x5 ^ x9, 12);
        x1 = (x1 + x5) | 0; x13 = rotl32(x13 ^ x1, 8);
        x9 = (x9 + x13) | 0; x5 = rotl32(x5 ^ x9, 7);

        x2 = (x2 + x6) | 0; x14 = rotl32(x14 ^ x2, 16);
        x10 = (x10 + x14) | 0; x6 = rotl32(x6 ^ x10, 12);
        x2 = (x2 + x6) | 0; x14 = rotl32(x14 ^ x2, 8);
        x10 = (x10 + x14) | 0; x6 = rotl32(x6 ^ x10, 7);

        x3 = (x3 + x7) | 0; x15 = rotl32(x15 ^ x3, 16);
        x11 = (x11 + x15) | 0; x7 = rotl32(x7 ^ x11, 12);
        x3 = (x3 + x7) | 0; x15 = rotl32(x15 ^ x3, 8);
        x11 = (x11 + x15) | 0; x7 = rotl32(x7 ^ x11, 7);

        x0 = (x0 + x5) | 0; x15 = rotl32(x15 ^ x0, 16);
        x10 = (x10 + x15) | 0; x5 = rotl32(x5 ^ x10, 12);
        x0 = (x0 + x5) | 0; x15 = rotl32(x15 ^ x0, 8);
        x10 = (x10 + x15) | 0; x5 = rotl32(x5 ^ x10, 7);

        x1 = (x1 + x6) | 0; x12 = rotl32(x12 ^ x1, 16);
        x11 = (x11 + x12) | 0; x6 = rotl32(x6 ^ x11, 12);
        x1 = (x1 + x6) | 0; x12 = rotl32(x12 ^ x1, 8);
        x11 = (x11 + x12) | 0; x6 = rotl32(x6 ^ x11, 7);

        x2 = (x2 + x7) | 0; x13 = rotl32(x13 ^ x2, 16);
        x8 = (x8 + x13) | 0; x7 = rotl32(x7 ^ x8, 12);
        x2 = (x2 + x7) | 0; x13 = rotl32(x13 ^ x2, 8);
        x8 = (x8 + x13) | 0; x7 = rotl32(x7 ^ x8, 7);

        x3 = (x3 + x4) | 0; x14 = rotl32(x14 ^ x3, 16);
        x9 = (x9 + x14) | 0; x4 = rotl32(x4 ^ x9, 12);
        x3 = (x3 + x4) | 0; x14 = rotl32(x14 ^ x3, 8);
        x9 = (x9 + x14) | 0; x4 = rotl32(x4 ^ x9, 7);
    }

    return (x0 ^ x1 ^ x2 ^ x3 ^ x4 ^ x5 ^ x6 ^ x7 ^
        x8 ^ x9 ^ x10 ^ x11 ^ x12 ^ x13 ^ x14 ^ x15) >>> 0;
}
