// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/fetch/headers.test.ts
// - reference/bun-v1.3.14/test/js/web/fetch/headers.undici.test.ts

describe("Headers", () => {
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

  test("global constructor prototype and iterator descriptors", () => {
    assert.equal(typeof Headers, "function");
    assert.equal(Headers.length, 0);
    assert.equal(Headers.name, "Headers");
    assert.throws(() => Headers(), TypeError);

    assertDataDescriptor(descriptor(globalThis, "Headers"), Headers, true, false, true, "global Headers");
    assertFunctionShape(Headers, "Headers", 0, true);
    assertDataDescriptor(descriptor(Headers, "prototype"), Headers.prototype, false, false, false, "Headers.prototype");
    assertDataDescriptor(descriptor(Headers.prototype, "constructor"), Headers, true, false, true, "Headers.prototype.constructor");
    assert.equal(Object.getPrototypeOf(Headers.prototype), Object.prototype);
    assert.equal(Headers.prototype[Symbol.toStringTag], "Headers");
    assertDataDescriptor(descriptor(Headers.prototype, Symbol.toStringTag), "Headers", false, false, true, "Headers.prototype Symbol.toStringTag");

    for (const [name, length] of [
      ["append", 2],
      ["delete", 1],
      ["get", 1],
      ["has", 1],
      ["set", 2],
      ["entries", 0],
      ["keys", 0],
      ["values", 0],
      ["forEach", 1],
      ["toJSON", 0],
      ["getSetCookie", 0],
    ]) {
      const property = descriptor(Headers.prototype, name);
      assert.equal(typeof property.value, "function", `${name} value`);
      assert.equal(property.enumerable, true, `${name} enumerable`);
      assert.equal(property.configurable, true, `${name} configurable`);
      assert.equal(property.writable, true, `${name} writable`);
      assertFunctionShape(property.value, name, length, false, `Headers.${name}`);
      assert.throws(() => property.value.call({}), TypeError);
    }

    const count = descriptor(Headers.prototype, "count");
    assert.equal(typeof count.get, "function");
    assert.equal(count.set, undefined);
    assert.equal(count.enumerable, true);
    assert.equal(count.configurable, false);
    assertFunctionShape(count.get, "get count", 0, false, "Headers.count getter");
    assert.equal(count.get.call({}), undefined);

    assertDataDescriptor(descriptor(Headers.prototype, Symbol.iterator), Headers.prototype.entries, true, false, true, "Headers.prototype @@iterator");

    const iterator = new Headers({ a: "1" }).entries();
    const iteratorPrototype = Object.getPrototypeOf(iterator);
    assert.equal(Object.prototype.toString.call(iterator), "[object Headers Iterator]");
    assertDataDescriptor(descriptor(iteratorPrototype, Symbol.toStringTag), "Headers Iterator", false, false, true, "Headers Iterator Symbol.toStringTag");
    assertFunctionShape(descriptor(iteratorPrototype, "next").value, "next", 0, false, "Headers Iterator.next");
    assert.equal(descriptor(iteratorPrototype, Symbol.iterator).value.call(iterator), iterator);
    assert.throws(() => descriptor(iteratorPrototype, "next").value.call({}), TypeError);
  });

  test("constructs from records, sequences, iterables, and existing Headers", () => {
    const fromRecord = new Headers({ "x-a": "1", "x-b": "2" });
    assert.equal(fromRecord.get("x-a"), "1");
    assert.equal(fromRecord.get("x-b"), "2");

    const fromSequence = new Headers([["x-a", "1"], ["x-a", "2"]]);
    assert.equal(fromSequence.get("x-a"), "1, 2");

    const iterable = {
      *[Symbol.iterator]() {
        yield ["x-duck", "ok"];
      },
    };
    assert.equal(new Headers(iterable).get("x-duck"), "ok");

    const copy = new Headers(fromSequence);
    assert.equal(copy.get("x-a"), "1, 2");
    assert.equal(Object.prototype.toString.call(copy), "[object Headers]");
  });

  test("subclassing preserves internal header list", () => {
    class SpecialHeaders extends Headers {}
    const headers = new SpecialHeaders({ "x-special": "1" });
    assert(headers instanceof SpecialHeaders);
    assert(headers instanceof Headers);
    headers.append("x-special", "2");
    assert.equal(headers.get("x-special"), "1, 2");
  });

  test("set-cookie keeps list form for server access while public APIs filter it", () => {
    const headers = new Headers([
      ["set-cookie", "a=1"],
      ["set-cookie", "b=2"],
    ]);
    assert.equal(headers.get("set-cookie"), null);
    assert.equal(headers.has("set-cookie"), false);
    assert.equal(headers.getSetCookie().join("|"), "a=1|b=2");
    assert.equal(Array.from(headers.keys()).join("|"), "");
    assert.equal(Array.from(headers.values()).join("|"), "");
    assert.equal(Array.from(headers).length, 0);
    assert.equal(JSON.stringify(headers), "{}");
    assert.equal(Array.from(new Headers(headers).getSetCookie()).join("|"), "a=1|b=2");
  });

  test("server-side count and toJSON hide set-cookie from generic exposure", () => {
    const headers = new Headers([
      ["x-request-id", "abc"],
      ["set-cookie", "a=1"],
      ["set-cookie", "b=2"],
      ["accept", "text/plain"],
      ["accept", "application/json"],
    ]);

    assert.equal(headers.count, 2);
    assert.deepEqual(headers.toJSON(), {
      "x-request-id": "abc",
      accept: "text/plain, application/json",
    });
    assert.equal(JSON.stringify(headers), '{"x-request-id":"abc","accept":"text/plain, application/json"}');
    assert.deepEqual(new Headers([["b", "2"], ["a", "1"]]).toJSON(), { b: "2", a: "1" });
    assert.deepEqual(new Headers([["set-cookie", "a=1"]]).toJSON(), {});

    assert.equal(Object.getOwnPropertyDescriptor(Headers.prototype, "count").enumerable, true);
    assert.equal(Object.getOwnPropertyDescriptor(Headers.prototype, "count").configurable, false);
    assert.equal(Object.getOwnPropertyDescriptor(Headers.prototype, "toJSON").enumerable, true);
    assert.equal(Object.getOwnPropertyDescriptor(Headers.prototype, "toJSON").configurable, true);
    assert.equal(Object.getOwnPropertyDescriptor(Headers.prototype, "get").enumerable, true);
    assert.equal(Object.keys(Headers.prototype).join(","), "append,delete,get,has,set,entries,keys,values,forEach,toJSON,count,getSetCookie");
    assert.throws(() => Headers.prototype.toJSON.call({}), TypeError);
    assert.equal(Object.getOwnPropertyDescriptor(Headers.prototype, "count").get.call({}), undefined);
  });

  test("iteration is sorted and live enough for mutations", () => {
    const sorted = new Headers([["b", "2"], ["a", "1"], ["b", "3"]]);
    assert.equal(Array.from(sorted).map(([key, value]) => `${key}:${value}`).join("|"), "a:1|b:2, 3");

    const moving = new Headers([["foo", "123"], ["bar", "456"]]);
    for (const [key, value] of moving) {
      moving.delete(key);
      moving.set(`x-${key}`, value);
    }
    assert.equal(Array.from(moving).map(([key, value]) => `${key}:${value}`).join("|"), "foo:123|x-x-bar:456");
  });

  test("validation, trimming, and tags", () => {
    const headers = new Headers({ "x-spaced": "  ok  " });
    headers.set("empty", "\r");
    headers.set("x-unicode", "café");
    assert.equal(headers.get("x-spaced"), "ok");
    assert.equal(headers.get("empty"), "");
    assert.equal(headers.get("x-unicode"), "café");

    assert.throws(() => new Headers(1), TypeError);
    assert.doesNotThrow(() => new Headers(new Number(1)));
    assert.throws(() => headers.get(), TypeError);
    assert.throws(() => headers.set("x"), TypeError);
    assert.throws(() => headers.set("bad name", "x"), TypeError);
    assert.throws(() => headers.set("x-bad", "a\rb"), TypeError);
    assert.equal(Object.prototype.toString.call(headers), "[object Headers]");
    assert.equal(Object.prototype.toString.call(headers.entries()), "[object Headers Iterator]");
    assert.equal(Headers.prototype[Symbol.iterator], Headers.prototype.entries);
    assert.throws(() => Headers(), TypeError);
  });

  test("many values keep aggregate and individual entries", () => {
    const headers = new Headers();
    for (let i = 0; i < 40; i++) {
      headers.append("x-many", String(i));
      headers.set(`x-${i}`, `v${i}`);
    }
    assert(headers.get("x-many").startsWith("0, 1, 2, 3"));
    assert.equal(headers.get("x-39"), "v39");
    assert.equal(Array.from(headers).length, 41);
  });

  test("append delete get has and set follow undici behavior", () => {
    const headers = new Headers();
    headers.append("undici", "fetch1");
    headers.append("undici", "fetch2");
    headers.append("undici", "fetch3");
    assert.equal(headers.get("undici"), "fetch1, fetch2, fetch3");
    assert.equal(headers.has("undici"), true);

    headers.set("undici", "fetch");
    assert.equal(headers.get("undici"), "fetch");
    assert.equal(headers.has("undici"), true);

    headers.delete("undici");
    assert.equal(headers.get("undici"), null);
    assert.equal(headers.has("undici"), false);

    assert.throws(() => headers.append(), TypeError);
    assert.throws(() => headers.append("undici"), TypeError);
    assert.throws(() => headers.append("invalid @ header ? name", "valid value"), TypeError);
    assert.throws(() => headers.delete(), TypeError);
    assert.throws(() => headers.get(), TypeError);
    assert.throws(() => headers.has(), TypeError);
    assert.throws(() => headers.set(), TypeError);
    assert.throws(() => headers.set("undici"), TypeError);
  });

  test("forEach receives value name object and thisArg", () => {
    const headers = new Headers([
      ["key", "value"],
      ["key2", "value2"],
    ]);
    const thisArg = { seen: [] };
    headers.forEach(function (value, name, object) {
      assert.equal(object, headers);
      this.seen.push(`${name}:${value}`);
    }, thisArg);
    assert.equal(thisArg.seen.join("|"), "key:value|key2:value2");
  });

  test("forEach snapshots entries when callback mutates headers", () => {
    const headers = new Headers([
      ["a", "1"],
      ["b", "2"],
      ["c", "3"],
    ]);
    const seen = [];
    headers.forEach((value, name, object) => {
      seen.push(`${name}:${value}`);
      object.delete(name);
    });
    assert.deepEqual(seen, ["a:1", "b:2", "c:3"]);
    assert.equal(headers.count(), 0);
  });

  test("iterators expose expected sorted entries", () => {
    const headers = new Headers([
      ["key", "value"],
      ["key2", "value2"],
    ]);
    assert.deepEqual([...headers.entries()], [["key", "value"], ["key2", "value2"]]);
    assert.deepEqual([...headers.keys()], ["key", "key2"]);
    assert.deepEqual([...headers.values()], ["value", "value2"]);
    assert.deepEqual([...headers], [["key", "value"], ["key2", "value2"]]);
  });

  test("invalid iterables are rejected", () => {
    assert.throws(() => new Headers([["undici", "fetch"], ["fetch"]]), TypeError);
    assert.throws(() => new Headers(["undici", "fetch", "fetch"]), TypeError);
    assert.throws(() => new Headers([0, 1, 2]), TypeError);
    assert.throws(() => new Headers([["key"]]), TypeError);
    assert.throws(() => new Headers([["key", "value", "value2"]]), TypeError);
  });
});
