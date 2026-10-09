// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/url/url.test.ts

function descriptor(obj, key) {
  const desc = Object.getOwnPropertyDescriptor(obj, key);
  assert(desc, `${String(key)} descriptor should exist`);
  return desc;
}

function assertDataDescriptor(desc, value, writable, enumerable, configurable, label) {
  assert.equal(desc.value, value, `${label} value`);
  assert.equal(desc.writable, writable, `${label} writable`);
  assert.equal(desc.enumerable, enumerable, `${label} enumerable`);
  assert.equal(desc.configurable, configurable, `${label} configurable`);
  assert.equal("get" in desc, false, `${label} should not be accessor`);
  assert.equal("set" in desc, false, `${label} should not be accessor`);
}

function assertFunctionShape(fn, name, length, hasPrototype, label = name) {
  assert.equal(typeof fn, "function", `${label} should be a function`);
  assertDataDescriptor(descriptor(fn, "name"), name, false, false, true, `${label}.name`);
  assertDataDescriptor(descriptor(fn, "length"), length, false, false, true, `${label}.length`);
  assert.equal(Object.hasOwn(fn, "prototype"), hasPrototype, `${label} prototype presence`);
}

describe("URL", () => {
  test("global constructor prototype descriptors and brand checks", () => {
    assert.equal(typeof URL, "function");
    assert.equal(URL.length, 1);
    assert.equal(URL.name, "URL");
    assert.throws(() => URL("https://example.com/"), TypeError);

    assertDataDescriptor(descriptor(globalThis, "URL"), URL, true, false, true, "global URL");
    assertFunctionShape(URL, "URL", 1, true);
    assertDataDescriptor(descriptor(URL, "prototype"), URL.prototype, false, false, false, "URL.prototype");
    assertDataDescriptor(descriptor(URL.prototype, "constructor"), URL, true, false, true, "URL.prototype.constructor");
    assert.equal(Object.getPrototypeOf(URL.prototype), Object.prototype);
    assertDataDescriptor(descriptor(URL.prototype, Symbol.toStringTag), "URL", false, false, true, "URL.prototype Symbol.toStringTag");

    const writableAccessors = ["href", "protocol", "username", "password", "host", "hostname", "port", "pathname", "search", "hash"];
    const readonlyAccessors = ["origin", "searchParams"];
    for (const name of [...writableAccessors, ...readonlyAccessors]) {
      const property = descriptor(URL.prototype, name);
      assert.equal(property.enumerable, true, `${name} enumerable`);
      assert.equal(property.configurable, true, `${name} configurable`);
      assertFunctionShape(property.get, `get ${name}`, 0, false, `URL.${name} getter`);
      assert.throws(() => property.get.call({}), TypeError);
      if (writableAccessors.includes(name)) {
        assertFunctionShape(property.set, `set ${name}`, 1, false, `URL.${name} setter`);
        assert.throws(() => property.set.call({}, "x"), TypeError);
      } else {
        assert.equal(property.set, undefined, `${name} setter`);
      }
    }

    for (const [name, length] of [["toString", 0], ["toJSON", 0]]) {
      const property = descriptor(URL.prototype, name);
      assertDataDescriptor(property, URL.prototype[name], true, true, true, `URL.prototype.${name}`);
      assertFunctionShape(property.value, name, length, false, `URL.${name}`);
      assert.throws(() => property.value.call({}), TypeError);
    }

    for (const [name, length] of [
      ["parse", 1],
      ["canParse", 1],
      ["createObjectURL", 1],
      ["revokeObjectURL", 1],
    ]) {
      const property = descriptor(URL, name);
      assertDataDescriptor(property, URL[name], true, false, true, `URL.${name}`);
      assertFunctionShape(property.value, name, length, false, `URL.${name}`);
    }

    assert.equal(Object.keys(URL.prototype).join(","), "href,origin,protocol,username,password,host,hostname,port,pathname,search,searchParams,hash,toString,toJSON");
    assert.equal(Object.prototype.toString.call(new URL("https://example.com/")), "[object URL]");
  });

  test("throws for invalid inputs", () => {
    assert.throws(() => new URL(), TypeError);
    assert.throws(() => new URL(""), TypeError);
    assert.throws(() => new URL(" "), TypeError);
    assert.throws(() => new URL("boop", "http!/example.com"), TypeError);
  });

  test("origin and protocol match WHATWG-special schemes", () => {
    const cases = [
      ["https://example.com", "https:", "https://example.com"],
      ["about:blank", "about:", "null"],
      ["http://example.com", "http:", "http://example.com"],
      ["ftp://example.com", "ftp:", "ftp://example.com"],
      ["file://example.com", "file:", "null"],
      ["ws://example.com", "ws:", "ws://example.com"],
      ["wss://example.com", "wss:", "wss://example.com"],
      ["kekjafek://example.com", "kekjafek:", "null"],
      ["data:text/plain,Hello%2C%20World!", "data:", "null"],
      ["blob://example.com", "blob:", "null"],
      ["javascript:alert('Hello World!')", "javascript:", "null"],
      ["mailto:", "mailto:", "null"],
    ];
    for (const [input, protocol, origin] of cases) {
      const url = new URL(input);
      assert.equal(url.protocol, protocol, `${input} protocol`);
      assert.equal(url.origin, origin, `${input} origin`);
    }
  });

  test("blob URL origins follow inner URL origin rules", () => {
    const cases = [
      ["blob:https://example.com/1234-5678", "https://example.com"],
      // File URLs have opaque origins (https://url.spec.whatwg.org/#concept-url-origin),
      // so blob URLs wrapping a file inner URL serialize their origin as "null".
      ["blob:file:///x", "null"],
      ["blob:file://text.txt", "null"],
      ["blob:file:///folder/else/text.txt", "null"],
      ["blob:kjka://example.com", "null"],
      ["blob:blob://example.com", "null"],
      ["blob:ws://example.com", "ws://example.com"],
    ];
    for (const [input, origin] of cases) {
      const url = new URL(input);
      assert.equal(url.protocol, "blob:", `${input} protocol`);
      assert.equal(url.origin, origin, `${input} origin`);
    }
  });

  test("serializes components", () => {
    const url = new URL("https://username:password@api.foo.bar.com:9999/baz/okay/i/123?ran=out&of=things#hash");
    assert.equal(url.hash, "#hash");
    assert.equal(url.host, "api.foo.bar.com:9999");
    assert.equal(url.hostname, "api.foo.bar.com");
    assert.equal(url.href, "https://username:password@api.foo.bar.com:9999/baz/okay/i/123?ran=out&of=things#hash");
    assert.equal(url.origin, "https://api.foo.bar.com:9999");
    assert.equal(url.password, "password");
    assert.equal(url.pathname, "/baz/okay/i/123");
    assert.equal(url.port, "9999");
    assert.equal(url.protocol, "https:");
    assert.equal(url.search, "?ran=out&of=things");
    assert.equal(url.username, "username");
  });

  test("URL.canParse behavior and arity", () => {
    const cases = [
      [undefined, undefined, false],
      ["a:b", undefined, true],
      [undefined, "a:b", false],
      ["a:/b", undefined, true],
      [undefined, "a:/b", true],
      ["https://test:test", undefined, false],
      ["a", "https://b/", true],
    ];
    for (const [url, base, expected] of cases)
      assert.equal(URL.canParse(url, base), expected, `URL.canParse(${url}, ${base})`);
    assert.throws(() => URL.canParse(), TypeError);
    assert.equal(URL.canParse.length, 1);
  });

  test("URL.parse returns URL objects or null", () => {
    const parsed = URL.parse("/path?q=1", "https://example.com/base");
    assert(parsed instanceof URL);
    assert.equal(parsed.href, "https://example.com/path?q=1");
    assert.equal(URL.parse("http://["), null);
    assert.equal(URL.parse("relative"), null);
    assert.throws(() => URL.parse(), TypeError);
    assert.equal(URL.parse.length, 1);
  });

  test("Blob object URLs are VM-local and revocable", () => {
    assert.equal(URL.createObjectURL.length, 1);
    assert.equal(URL.revokeObjectURL.length, 1);

    const first = URL.createObjectURL(new Blob(["hello"], { type: "text/plain" }));
    const second = URL.createObjectURL(new Blob(["hello"], { type: "text/plain" }));
    assert(first.startsWith("blob:"), first);
    assert(second.startsWith("blob:"), second);
    assert(first !== second, "object URLs should be unique");
    assert.equal(URL.canParse(first), true);

    URL.revokeObjectURL(first);
    URL.revokeObjectURL(first);
    URL.revokeObjectURL("blob:not-registered");
    URL.revokeObjectURL(second);

    assert.throws(() => URL.createObjectURL({}), TypeError);
    assert.throws(() => URL.revokeObjectURL(), TypeError);
  });

  test("subclassing uses new.target structure", () => {
    class CustomURL extends URL {}
    const custom = new CustomURL("/path?x=1", "https://example.com/base");
    assert(custom instanceof CustomURL);
    assert(custom instanceof URL);
    assert.equal(Object.getPrototypeOf(custom), CustomURL.prototype);
    assert.equal(custom.href, "https://example.com/path?x=1");
    assert(custom.searchParams instanceof URLSearchParams);
    custom.searchParams.set("x", "2");
    assert.equal(custom.search, "?x=2");
  });

  test("setters preserve state on invalid href and use USVString conversion", () => {
    const url = new URL("https://user:pass@example.com:8080/a?x=1#old");
    const params = url.searchParams;

    assert.throws(() => {
      url.href = "http://[";
    }, TypeError);
    assert.equal(url.href, "https://user:pass@example.com:8080/a?x=1#old");
    assert.equal(url.searchParams, params);

    url.pathname = "/a\uD800b";
    url.search = "?q=\uD800";
    url.hash = "#\uD800";
    url.username = "u\uD800";
    url.password = "p\uDC00";
    assert.equal(url.pathname, "/a%EF%BF%BDb");
    assert.equal(url.search, "?q=%EF%BF%BD");
    assert.equal(url.hash, "#%EF%BF%BD");
    assert.equal(url.username, "u%EF%BF%BD");
    assert.equal(url.password, "p%EF%BF%BD");
    assert.deepEqual(Array.from(url.searchParams), [["q", "�"]]);

    const parsed = URL.parse("/\uD800?q=\uDC00", "https://example.com/");
    assert.equal(parsed.href, "https://example.com/%EF%BF%BD?q=%EF%BF%BD");
  });

  test("URLSearchParams association is live", () => {
    const url = new URL("https://example.com/?a=1");
    url.searchParams.append("b", "hello world");
    assert.equal(url.search, "?a=1&b=hello+world");
    url.search = "?c=3";
    assert.equal(url.searchParams.get("c"), "3");
    assert.equal(url.href, "https://example.com/?c=3");
  });

  test("username/password/host/hostname setters honor null-vs-empty host and opaque paths", () => {
    // WHATWG "cannot have a username/password/port": host is null OR empty, or
    // scheme is file. A special URL whose host is the empty string still cannot
    // carry credentials.
    const noHost = new URL("https://example.com/path");
    noHost.username = "bob";
    noHost.password = "secret";
    assert.equal(noHost.username, "bob");
    assert.equal(noHost.password, "secret");

    // file: scheme cannot carry credentials regardless of host.
    const file = new URL("file:///etc/passwd");
    file.username = "bob";
    file.password = "secret";
    assert.equal(file.username, "");
    assert.equal(file.password, "");

    // Opaque-path (non-special) URLs have a null host and cannot set host/port.
    const opaque = new URL("mailto:user@example.com");
    assert.equal(opaque.host, "");
    assert.equal(opaque.hostname, "");
    opaque.username = "x";
    opaque.password = "y";
    assert.equal(opaque.username, "");
    assert.equal(opaque.password, "");
    opaque.host = "evil.com";
    opaque.hostname = "evil.com";
    assert.equal(opaque.host, "");
    assert.equal(opaque.hostname, "");
    assert.equal(opaque.href, "mailto:user@example.com");

    // Empty host on a special non-file scheme is rejected by the host setters.
    const special = new URL("https://example.com/p");
    special.host = "";
    assert.equal(special.hostname, "example.com");
    special.hostname = "";
    assert.equal(special.hostname, "example.com");

    // Non-special scheme that allows an empty host accepts hostname changes.
    const nonSpecial = new URL("foo://example.com/p");
    nonSpecial.hostname = "other.example";
    assert.equal(nonSpecial.hostname, "other.example");

    // A failed host setter must not corrupt the rest of the URL.
    const intact = new URL("https://user:pass@example.com:8443/a?x=1#h");
    intact.host = "bad host with spaces";
    assert.equal(intact.href, "https://user:pass@example.com:8443/a?x=1#h");
  });
});
