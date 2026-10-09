// Collo-only.

bench("globals.lookup-installed-webapis", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    checksum += typeof URL === "function";
    checksum += typeof URLSearchParams === "function";
    checksum += typeof URLPattern === "function";
    checksum += typeof DOMException === "function";
    checksum += typeof Event === "function";
    checksum += typeof CustomEvent === "function";
    checksum += typeof MessageEvent === "function";
    checksum += typeof MessageChannel === "function";
    checksum += typeof MessagePort === "function";
    checksum += typeof ErrorEvent === "function";
    checksum += typeof CloseEvent === "function";
    checksum += typeof EventTarget === "function";
    checksum += typeof addEventListener === "function";
    checksum += typeof removeEventListener === "function";
    checksum += typeof dispatchEvent === "function";
    checksum += globalThis.onerror === null || typeof globalThis.onerror === "function";
    checksum += globalThis.onmessage === null || typeof globalThis.onmessage === "function";
    checksum += typeof Performance === "function";
    checksum += typeof PerformanceEntry === "function";
    checksum += typeof PerformanceMark === "function";
    checksum += typeof PerformanceMeasure === "function";
    checksum += typeof PerformanceTiming === "function";
    checksum += typeof PerformanceObserver === "function";
    checksum += typeof PerformanceObserverEntryList === "function";
    checksum += typeof performance === "object";
    checksum += typeof Blob === "function";
    checksum += typeof File === "function";
    checksum += typeof FormData === "function";
    checksum += typeof crypto === "object";
    checksum += typeof Crypto === "function";
    checksum += typeof SubtleCrypto === "function";
    checksum += typeof CryptoKey === "function";
    checksum += typeof Headers === "function";
    checksum += typeof Request === "function";
    checksum += typeof Response === "function";
    checksum += typeof fetch === "function";
    checksum += typeof setTimeout === "function";
    checksum += typeof clearTimeout === "function";
    checksum += typeof queueMicrotask === "function";
    checksum += typeof atob === "function";
    checksum += typeof btoa === "function";
    checksum += typeof structuredClone === "function";
    checksum += typeof reportError === "function";
    checksum += typeof navigator === "object";
    checksum += typeof console === "object";
  }
  return checksum;
}, { iterations: 200000, warmup: 10000 });
