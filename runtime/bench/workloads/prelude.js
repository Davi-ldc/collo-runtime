"use strict";

let __lastDigest = 0;
let __acc = 0x811c9dc5 | 0;
let __totalCalls = 0;

function rotl32(x, n) {
    return (x << n) | (x >>> (32 - n));
}

function rotr32(x, n) {
    return (x >>> n) | (x << (32 - n));
}
