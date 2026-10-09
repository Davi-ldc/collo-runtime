// 40 distinct functions, each with a unique body so JSC cannot share a single
// CodeBlock. Every call invokes all of them, so they all tier up across the
// run. JIT writes executable memory per-process AFTER fork, so this footprint
// is always private (anonymous_executable_jit) -- it measures why pre-JIT in
// the zygote does not share.
// More calls -> deeper tier-up (Baseline -> DFG -> FTL) -> more private pages.
function f00(x){return (x*3+1)|0;}
function f01(x){return (x^0x5bd1e995)|0;}
function f02(x){return (x+(x<<3))|0;}
function f03(x){return (x-(x>>>2))|0;}
function f04(x){return Math.imul(x,0x9e3779b9)|0;}
function f05(x){return (x^(x>>>15))|0;}
function f06(x){return ((x|7)*5)|0;}
function f07(x){return (x&0x00ff00ff)|0;}
function f08(x){return (x+0x7f4a7c15)|0;}
function f09(x){return ((x<<13)^x)|0;}
function f10(x){return (x*0x27d4eb2f)|0;}
function f11(x){return (x^(x<<7)^0x2545f491)|0;}
function f12(x){return ((x>>>1)|(x<<31))|0;}
function f13(x){return (x+(x*x))|0;}
function f14(x){return (x^0xdeadbeef)|0;}
function f15(x){return (((x*9)>>>3)+2)|0;}
function f16(x){return (x-0x61c88647)|0;}
function f17(x){return (x^(x>>>11)^(x<<5))|0;}
function f18(x){return Math.imul(x^0x85ebca6b,0xc2b2ae35)|0;}
function f19(x){return ((x&0xffff)*0x1000193)|0;}
function f20(x){return (x+(x>>>8)+0x13)|0;}
function f21(x){return ((x<<3)-(x>>>5))|0;}
function f22(x){return (x^0x6a09e667)|0;}
function f23(x){return ((x|1)*(x|3))|0;}
function f24(x){return (x^(x>>>16))*0x45d9f3b|0;}
function f25(x){return (x+0x428a2f98)|0;}
function f26(x){return ((x>>>4)^(x<<12))|0;}
function f27(x){return Math.imul(x,31)^Math.imul(x,17)|0;}
function f28(x){return (x-(x<<6))|0;}
function f29(x){return (x^0x3c6ef372^(x>>>3))|0;}
function f30(x){return ((x*7)+(x>>>9))|0;}
function f31(x){return (x&0x0f0f0f0f)|(x>>>13)|0;}
function f32(x){return (x^0xa54ff53a)|0;}
function f33(x){return ((x<<2)+x+1)|0;}
function f34(x){return (x*0x100000001>>>0)|0;}
function f35(x){return (x^(x<<17)^(x>>>7))|0;}
function f36(x){return ((x>>>6)*0x5c)|0;}
function f37(x){return (x+0xbb67ae85)|0;}
function f38(x){return Math.imul(x|5,0x1b873593)|0;}
function f39(x){return (x^(x>>>19)^0x71374491)|0;}

const __FNS = [
    f00, f01, f02, f03, f04, f05, f06, f07, f08, f09,
    f10, f11, f12, f13, f14, f15, f16, f17, f18, f19,
    f20, f21, f22, f23, f24, f25, f26, f27, f28, f29,
    f30, f31, f32, f33, f34, f35, f36, f37, f38, f39,
];

function workloadKernel(iterations) {
    let digest = __totalCalls | 0;
    for (let i = 0; i < iterations; i++) {
        for (let f = 0; f < __FNS.length; f++) {
            digest = __FNS[f](digest ^ i) | 0;
        }
    }
    return digest >>> 0;
}
