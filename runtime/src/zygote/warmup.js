// Zygote warmup corpus; it belongs to no application.
//
// Evaluated once in the zygote VM before the first fork so that lazily
// materialized JSC structures (builtin bytecode, Structure caches, RegExp,
// JSON, URL, Promise, TypedArray, TextEncoder paths) land in copy-on-write
// pages shared by every forked worker. It must not depend on any request
// context: no fetch, no timers, no per-request bindings. Loop bounds stay
// small on purpose; the goal is materializing structures, not JIT tiers.

let microtaskTicks = 0;

function mix(digest, value) {
    return ((digest ^ value) * 0x01000193) >>> 0;
}

function warmJson(digest) {
    const text = '{"name":"warm\\u00e9","values":[1,2.5,-3e2,true,false,null],' +
        '"nested":{"deep":{"list":[{"id":1},{"id":2}],"flag":true}},"unicode":"\\ud83d\\ude00"}';
    const parsed = JSON.parse(text);
    digest = mix(digest, parsed.values.length);
    digest = mix(digest, parsed.nested.deep.list[1].id);
    const round = JSON.stringify(parsed, null, 2);
    digest = mix(digest, round.length);
    const filtered = JSON.stringify(parsed, ["name", "nested", "deep", "flag"]);
    digest = mix(digest, filtered.length);
    digest = mix(digest, JSON.stringify([new Date(0)]).length);
    return digest;
}

function warmRegExp(digest) {
    const router = /^\/api\/(?<version>v\d+)\/users\/(?<id>\d+)$/;
    const matched = router.exec("/api/v2/users/12345");
    digest = mix(digest, matched.groups.id.length);
    digest = mix(digest, matched.groups.version === "v2" ? 7 : 0);

    const global = /[aeiou]/g;
    let count = 0;
    while (global.exec("the quick brown fox jumps over the lazy dog") !== null) {
        count += 1;
        if (count > 64) break;
    }
    digest = mix(digest, count);

    digest = mix(digest, "a-b_c d,e".split(/[-_ ,]/).length);
    digest = mix(digest, "hello world".replace(/o/g, (c) => c.toUpperCase()).length);
    digest = mix(digest, /\p{L}+/u.test("héllo") ? 11 : 0);
    const sticky = /\d+/y;
    sticky.lastIndex = 3;
    digest = mix(digest, sticky.test("abc123") ? 13 : 0);
    digest = mix(digest, ("x".repeat(8) + "y").search(/y/));
    return digest;
}

function warmString(digest) {
    const base = "Construirar o runtime serverless – ração 10x más rápido";
    digest = mix(digest, base.normalize("NFC").length);
    digest = mix(digest, base.toUpperCase().length);
    digest = mix(digest, base.toLowerCase().codePointAt(3));
    digest = mix(digest, base.padStart(70, ".").length);
    digest = mix(digest, base.trim().slice(4, 14).length);
    digest = mix(digest, base.includes("runtime") ? 17 : 0);
    digest = mix(digest, base.startsWith("Cons") ? 19 : 0);
    digest = mix(digest, base.endsWith("rápido") ? 23 : 0);
    digest = mix(digest, base.indexOf("serverless"));
    digest = mix(digest, base.split(" ").join("-").length);
    digest = mix(digest, "a".localeCompare("b") < 0 ? 29 : 0);
    digest = mix(digest, String.raw`tem\plate ${1 + 1}`.length);
    digest = mix(digest, encodeURIComponent("q=a b&ç").length);
    digest = mix(digest, decodeURIComponent("q%3Da%20b").length);
    digest = mix(digest, String.fromCharCode(72, 105).length);
    digest = mix(digest, parseInt("ff", 16));
    digest = mix(digest, Math.round(parseFloat("3.5e1")));
    digest = mix(digest, (1234.5678).toFixed(2).length);
    digest = mix(digest, (255).toString(16).length);
    return digest;
}

function warmArray(digest) {
    const values = Array.from({ length: 48 }, (_, i) => (i * 37) % 19);
    const mapped = values.map((v) => v * 2 + 1);
    const filtered = mapped.filter((v) => v % 3 !== 0);
    const sortedNumeric = filtered.slice().sort((a, b) => a - b);
    const sortedLexical = values.map(String).sort();
    digest = mix(digest, sortedNumeric[0]);
    digest = mix(digest, sortedLexical.length);
    digest = mix(digest, values.reduce((acc, v) => acc + v, 0));
    digest = mix(digest, [[1, 2], [3, [4, 5]]].flat(2).length);
    digest = mix(digest, values.flatMap((v) => [v, v + 1]).length);
    digest = mix(digest, values.includes(7) ? 31 : 0);
    digest = mix(digest, values.indexOf(0));
    const scratch = values.slice(0, 16);
    scratch.fill(9, 2, 5);
    scratch.copyWithin(0, 8, 12);
    scratch.splice(1, 2, 41, 42);
    digest = mix(digest, scratch.concat([1, 2]).length);
    const [first = 0, ...rest] = scratch;
    digest = mix(digest, first + rest.length);
    digest = mix(digest, Math.max(...values.slice(0, 8)));
    digest = mix(digest, Array.of(1, 2, 3).length);
    return digest;
}

function warmTypedArray(digest) {
    const bytes = new Uint8Array(64);
    for (let i = 0; i < bytes.length; i += 1) bytes[i] = (i * 31) & 0xff;
    const ints = new Int32Array(bytes.buffer, 0, 8);
    const floats = new Float64Array(4);
    floats.set([1.5, -2.25, 3.75, 0.125]);
    const view = new DataView(bytes.buffer);
    view.setUint32(8, 0xdeadbeef, true);
    digest = mix(digest, view.getUint32(8, true) & 0xffff);
    digest = mix(digest, ints[2] & 0xff);
    digest = mix(digest, Math.round(floats[1] * -4));
    digest = mix(digest, bytes.subarray(4, 12).length);
    digest = mix(digest, new Uint8Array(bytes.buffer.slice(0, 16)).length);
    const sorted = Uint8Array.from([9, 1, 5, 3]).sort();
    digest = mix(digest, sorted[0]);
    digest = mix(digest, new BigInt64Array([1n, -2n])[1] === -2n ? 37 : 0);
    return digest;
}

function warmCollections(digest) {
    const map = new Map();
    const set = new Set();
    for (let i = 0; i < 24; i += 1) {
        map.set("key-" + i, i * i);
        set.add(i % 7);
    }
    map.delete("key-3");
    digest = mix(digest, map.size);
    digest = mix(digest, set.size);
    digest = mix(digest, map.get("key-5"));
    let sum = 0;
    for (const [, value] of map) sum = (sum + value) | 0;
    for (const value of set) sum = (sum + value) | 0;
    digest = mix(digest, sum >>> 0);
    const weakKey = { id: 1 };
    const weakMap = new WeakMap([[weakKey, "v"]]);
    const weakSet = new WeakSet([weakKey]);
    digest = mix(digest, weakMap.has(weakKey) && weakSet.has(weakKey) ? 41 : 0);
    return digest;
}

function warmObjectsAndClasses(digest) {
    class Shape {
        #area;
        constructor(area) {
            this.#area = area;
        }
        get area() {
            return this.#area;
        }
        static kind() {
            return "shape";
        }
    }
    class Square extends Shape {
        constructor(side) {
            super(side * side);
            this.side = side;
        }
        toString() {
            return `square:${this.side}`;
        }
    }
    const square = new Square(6);
    digest = mix(digest, square.area);
    digest = mix(digest, square instanceof Shape ? 43 : 0);
    digest = mix(digest, String(square).length);
    digest = mix(digest, Shape.kind().length);

    const source = { a: 1, b: 2, get c() { return 3; } };
    const target = Object.assign(Object.create(null), source);
    Object.defineProperty(target, "d", { value: 4, enumerable: true });
    digest = mix(digest, Object.keys(target).length);
    digest = mix(digest, Object.values(source).length);
    digest = mix(digest, Object.entries(source).length);
    digest = mix(digest, Object.isFrozen(Object.freeze({})) ? 47 : 0);
    digest = mix(digest, Object.prototype.hasOwnProperty.call(source, "b") ? 53 : 0);

    const proxied = new Proxy({ value: 5 }, {
        get(obj, prop) {
            return prop === "value" ? obj.value * 2 : Reflect.get(obj, prop);
        },
    });
    digest = mix(digest, proxied.value);
    digest = mix(digest, Reflect.ownKeys({ x: 1 }).length);
    digest = mix(digest, (source?.missing?.deep ?? 59));
    return digest;
}

function* sequence(limit) {
    for (let i = 0; i < limit; i += 1) yield i * 3;
}

function warmIterators(digest) {
    let total = 0;
    for (const value of sequence(12)) total += value;
    digest = mix(digest, total);
    const iterable = {
        [Symbol.iterator]() {
            let i = 0;
            return { next: () => (i < 4 ? { value: i++, done: false } : { value: undefined, done: true }) };
        },
    };
    digest = mix(digest, [...iterable].length);
    digest = mix(digest, typeof Symbol("tag") === "symbol" ? 61 : 0);
    return digest;
}

function warmErrors(digest) {
    try {
        JSON.parse("{not json");
    } catch (err) {
        digest = mix(digest, err instanceof SyntaxError ? 67 : 0);
        digest = mix(digest, typeof err.stack === "string" ? 71 : 0);
    }
    try {
        null.missing;
    } catch (err) {
        digest = mix(digest, err instanceof TypeError ? 73 : 0);
    }
    class AppError extends Error {
        constructor(message, options) {
            super(message, options);
            this.name = "AppError";
        }
    }
    const wrapped = new AppError("warmup", { cause: new RangeError("inner") });
    digest = mix(digest, wrapped.cause instanceof RangeError ? 79 : 0);
    digest = mix(digest, wrapped.message.length);
    return digest;
}

function warmDateAndMath(digest) {
    const epoch = new Date(0);
    digest = mix(digest, epoch.toISOString().length);
    digest = mix(digest, epoch.getTime() === 0 ? 83 : 0);
    digest = mix(digest, new Date(Date.UTC(2026, 0, 2, 3, 4, 5)).getUTCHours());
    digest = mix(digest, Date.parse("2026-01-02T03:04:05.000Z") % 97);
    digest = mix(digest, Math.round(Math.sqrt(144)));
    digest = mix(digest, Math.floor(Math.log2(1024)));
    digest = mix(digest, Math.abs(Math.min(-3, 2)));
    digest = mix(digest, Math.trunc(Math.cosh(0) + Math.atan2(1, 1) * 4));
    digest = mix(digest, Number((123n * 456n) % 251n));
    digest = mix(digest, Number.isInteger(42) && Number.isFinite(0.5) ? 89 : 0);
    return digest;
}

function warmWebApis(digest) {
    if (typeof TextEncoder === "function" && typeof TextDecoder === "function") {
        const encoder = new TextEncoder();
        const decoder = new TextDecoder();
        const encoded = encoder.encode("warmup ação 😀");
        digest = mix(digest, encoded.length);
        digest = mix(digest, decoder.decode(encoded).length);
    }
    if (typeof URL === "function") {
        const url = new URL("https://user:pass@example.test:8443/a/b%20c?x=1&y=two#frag");
        digest = mix(digest, url.pathname.length);
        digest = mix(digest, url.port.length);
        url.searchParams.append("z", "três");
        url.searchParams.sort();
        digest = mix(digest, url.searchParams.get("y").length);
        digest = mix(digest, url.toString().length);
        digest = mix(digest, new URL("../up?q=1", "https://example.test/a/b/c").pathname.length);
    }
    if (typeof URLSearchParams === "function") {
        const params = new URLSearchParams("a=1&b=2&a=3");
        digest = mix(digest, params.getAll("a").length);
    }
    if (typeof crypto === "object" && crypto !== null) {
        if (typeof crypto.getRandomValues === "function") {
            digest = mix(digest, crypto.getRandomValues(new Uint8Array(16)).length);
        }
        if (typeof crypto.randomUUID === "function") {
            digest = mix(digest, crypto.randomUUID().length);
        }
    }
    if (typeof structuredClone === "function") {
        const cloned = structuredClone({ list: [1, 2, 3], nested: { ok: true } });
        digest = mix(digest, cloned.list.length + (cloned.nested.ok ? 1 : 0));
    }
    if (typeof queueMicrotask === "function") {
        queueMicrotask(() => {
            microtaskTicks += 1;
        });
        digest = mix(digest, 101);
    }
    return digest;
}

async function warmAsync() {
    const first = await Promise.resolve(11);
    const settled = await Promise.allSettled([
        Promise.resolve(1),
        Promise.reject(new Error("expected-rejection")),
    ]);
    const all = await Promise.all([Promise.resolve(2), 3, Promise.resolve(4)]);
    const raced = await Promise.race([Promise.resolve("fast"), new Promise(() => {})]);
    return first + settled.length + all.length + raced.length;
}

function warmPromises(digest) {
    Promise.resolve(1)
        .then((v) => v + 1)
        .then((v) => {
            microtaskTicks += v;
        })
        .catch(() => {
            microtaskTicks = -1;
        })
        .finally(() => {
            microtaskTicks += 1;
        });
    warmAsync().then((value) => {
        microtaskTicks += value;
    });
    new Promise((resolve) => resolve(7)).then((v) => {
        microtaskTicks += v;
    });
    digest = mix(digest, 103);
    return digest;
}

function warmIntl(digest) {
    if (typeof Intl !== "object" || Intl === null) return digest;
    // Materialize the lazy Intl structures once in the zygote with neutral,
    // tenant-free arguments (default locale, constant types) so the
    // LazyProperty / LazyClassStructure callbacks fire pre-fork and the
    // materialized structures land in copy-on-write pages shared by every
    // worker. Workers that use Intl then inherit them shared instead of
    // re-materializing them privately.
    if (typeof Intl.Collator === "function") {
        digest = mix(digest, new Intl.Collator().compare("a", "b") < 0 ? 1 : 0);
    }
    if (typeof Intl.NumberFormat === "function") {
        digest = mix(digest, new Intl.NumberFormat().format(1234.5).length);
    }
    if (typeof Intl.DateTimeFormat === "function") {
        digest = mix(digest, new Intl.DateTimeFormat().format(new Date(0)).length);
    }
    if (typeof Intl.PluralRules === "function") {
        digest = mix(digest, new Intl.PluralRules().select(1).length);
    }
    if (typeof Intl.RelativeTimeFormat === "function") {
        digest = mix(digest, new Intl.RelativeTimeFormat().format(-1, "day").length);
    }
    if (typeof Intl.ListFormat === "function") {
        digest = mix(digest, new Intl.ListFormat().format(["a", "b"]).length);
    }
    if (typeof Intl.DisplayNames === "function") {
        digest = mix(digest, new Intl.DisplayNames(["en"], { type: "language" }).of("pt").length);
    }
    if (typeof Intl.Segmenter === "function") {
        digest = mix(digest, Array.from(new Intl.Segmenter().segment("ab")).length);
    }
    return digest;
}

export default function runWarmupCorpus() {
    let digest = 0x811c9dc5 >>> 0;
    digest = warmJson(digest);
    digest = warmRegExp(digest);
    digest = warmString(digest);
    digest = warmArray(digest);
    digest = warmTypedArray(digest);
    digest = warmCollections(digest);
    digest = warmObjectsAndClasses(digest);
    digest = warmIterators(digest);
    digest = warmErrors(digest);
    digest = warmDateAndMath(digest);
    digest = warmIntl(digest);
    digest = warmWebApis(digest);
    digest = warmPromises(digest);
    return String(digest >>> 0);
}
