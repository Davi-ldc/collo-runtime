// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/html/URLSearchParams.test.ts

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

describe("URLSearchParams", () => {
  test("record and iterable initializers serialize with form encoding", () => {
    assert.equal(new URLSearchParams({ q: "hello world" }).toString(), "q=hello+world");
    assert.equal(new URLSearchParams([["z", "2"], ["a", "hello world"]]).toString(), "z=2&a=hello+world");
  });

  test("iterable initializer pair rejects a third item before draining the tail", () => {
    let nextCalls = 0;
    let tailRead = false;
    let closed = false;
    const pair = {
      [Symbol.iterator]() {
        return {
          next() {
            nextCalls++;
            if (nextCalls === 1)
              return { value: "a", done: false };
            if (nextCalls === 2)
              return { value: "b", done: false };
            if (nextCalls === 3)
              return { value: "c", done: false };
            if (nextCalls === 4) {
              tailRead = true;
              return { value: "tail", done: false };
            }
            return { value: undefined, done: true };
          },
          return() {
            closed = true;
            return { done: true };
          },
        };
      },
    };

    assert.throws(() => new URLSearchParams([pair]), TypeError);
    assert.equal(nextCalls, 3);
    assert.equal(tailRead, false);
    assert.equal(closed, true);
  });

  test("global constructor prototype iterator descriptors and brand checks", () => {
    assert.equal(typeof URLSearchParams, "function");
    assert.equal(URLSearchParams.length, 0);
    assert.equal(URLSearchParams.name, "URLSearchParams");
    assert.throws(() => URLSearchParams("a=1"), TypeError);

    assertDataDescriptor(descriptor(globalThis, "URLSearchParams"), URLSearchParams, true, false, true, "global URLSearchParams");
    assertFunctionShape(URLSearchParams, "URLSearchParams", 0, true);
    assertDataDescriptor(descriptor(URLSearchParams, "prototype"), URLSearchParams.prototype, false, false, false, "URLSearchParams.prototype");
    assertDataDescriptor(descriptor(URLSearchParams.prototype, "constructor"), URLSearchParams, true, false, true, "URLSearchParams.prototype.constructor");
    assert.equal(Object.getPrototypeOf(URLSearchParams.prototype), Object.prototype);
    assertDataDescriptor(descriptor(URLSearchParams.prototype, Symbol.toStringTag), "URLSearchParams", false, false, true, "URLSearchParams.prototype Symbol.toStringTag");

    for (const [name, length] of [
      ["append", 2],
      ["delete", 1],
      ["get", 1],
      ["getAll", 1],
      ["has", 1],
      ["set", 2],
      ["sort", 0],
      ["entries", 0],
      ["keys", 0],
      ["values", 0],
      ["forEach", 1],
      ["toString", 0],
      ["toJSON", 0],
    ]) {
      const property = descriptor(URLSearchParams.prototype, name);
      assertDataDescriptor(property, URLSearchParams.prototype[name], true, true, true, `URLSearchParams.prototype.${name}`);
      assertFunctionShape(property.value, name, length, false, `URLSearchParams.${name}`);
      assert.throws(() => property.value.call({}), TypeError);
    }

    const size = descriptor(URLSearchParams.prototype, "size");
    assert.equal(size.enumerable, true);
    assert.equal(size.configurable, true);
    assert.equal(size.set, undefined);
    assertFunctionShape(size.get, "get size", 0, false, "URLSearchParams.size getter");
    assert.throws(() => size.get.call({}), TypeError);

    assertDataDescriptor(descriptor(URLSearchParams.prototype, Symbol.iterator), URLSearchParams.prototype.entries, true, false, true, "URLSearchParams.prototype @@iterator");
    assert.equal(Object.keys(URLSearchParams.prototype).join(","), "append,delete,get,getAll,has,set,sort,entries,keys,values,forEach,toString,toJSON,size");

    const params = new URLSearchParams("i=1&i=2");
    const iterator = params.entries();
    const iteratorPrototype = Object.getPrototypeOf(iterator);
    assert.equal(Object.prototype.toString.call(params), "[object URLSearchParams]");
    assert.equal(Object.prototype.toString.call(iterator), "[object URLSearchParams Iterator]");
    assertDataDescriptor(descriptor(iteratorPrototype, Symbol.toStringTag), "URLSearchParams Iterator", false, false, true, "URLSearchParams Iterator Symbol.toStringTag");
    assertFunctionShape(descriptor(iteratorPrototype, "next").value, "next", 0, false, "URLSearchParams Iterator.next");
    assertFunctionShape(descriptor(iteratorPrototype, Symbol.iterator).value, "[Symbol.iterator]", 0, false, "URLSearchParams Iterator @@iterator");
    assert.equal(descriptor(iteratorPrototype, Symbol.iterator).value.call(iterator), iterator);
    assert.equal(descriptor(iteratorPrototype, Symbol.iterator).value.call({}).constructor, Object);
    assert.throws(() => descriptor(iteratorPrototype, "next").value.call({}), TypeError);
  });

  test("delete second argument", () => {
    const params = new URLSearchParams("a=1&a=2&b=3");
    params.delete("a", 1);
    params.delete("b", undefined);
    assert.equal(params + "", "a=2");
  });

  test("has second argument", () => {
    const params = new URLSearchParams("a=1&a=2&b=3");
    assert.equal(params.has("a", 1), true);
    assert.equal(params.has("a", 2), true);
    assert.equal(params.has("a", 3), false);
    assert.equal(params.has("b", 3), true);
    assert.equal(params.has("b", 4), false);
  });

  test("sort follows stable WPT ordering and syncs associated URL", () => {
    const cases = [
      ["z=b&a=b&z=a&a=a", [["a", "b"], ["a", "a"], ["z", "b"], ["z", "a"]]],
      ["\uFFFD=x&\uFFFC&\uFFFD=a", [["\uFFFC", ""], ["\uFFFD", "x"], ["\uFFFD", "a"]]],
      ["ﬃ&🌈", [["🌈", ""], ["ﬃ", ""]]],
      ["é&e\uFFFD&e\u0301", [["e\u0301", ""], ["e\uFFFD", ""], ["é", ""]]],
      [
        "z=z&a=a&z=y&a=b&z=x&a=c&z=w&a=d&z=v&a=e&z=u&a=f&z=t&a=g",
        [["a", "a"], ["a", "b"], ["a", "c"], ["a", "d"], ["a", "e"], ["a", "f"], ["a", "g"], ["z", "z"], ["z", "y"], ["z", "x"], ["z", "w"], ["z", "v"], ["z", "u"], ["z", "t"]],
      ],
      ["bbb&bb&aaa&aa=x&aa=y", [["aa", "x"], ["aa", "y"], ["aaa", ""], ["bb", ""], ["bbb", ""]]],
      ["z=z&=f&=t&=x", [["", "f"], ["", "t"], ["", "x"], ["z", "z"]]],
      ["a🌈&a💩", [["a🌈", ""], ["a💩", ""]]],
    ];

    for (const [input, output] of cases) {
      const params = new URLSearchParams(input);
      assert.equal(params.sort(), undefined);
      assert.deepEqual(Array.from(params), output, input);

      const url = new URL("?" + input, "https://example/");
      url.searchParams.sort();
      assert.deepEqual(Array.from(new URLSearchParams(url.search)), output, `url ${input}`);
    }

    const empty = new URL("http://example.com/?");
    empty.searchParams.sort();
    assert.equal(empty.href, "http://example.com/");
    assert.equal(empty.search, "");
  });

  test("required argument checks", () => {
    const params = new URLSearchParams();
    assert.throws(() => params.append("a"), TypeError);
    assert.throws(() => params.set("a"), TypeError);
    assert.throws(() => params.get(), TypeError);
    assert.throws(() => params.getAll(), TypeError);
    assert.throws(() => params.has(), TypeError);
    assert.throws(() => params.delete(), TypeError);
  });

  test("iteration order, tags, and constructor call shape", () => {
    const params = new URLSearchParams("i=1&i=2");
    assert.equal(Array.from(params.entries()).map(pair => pair.join(":")).join(","), "i:1,i:2");
    assert.equal(params[Symbol.iterator], params.entries);
    assert.equal(Object.prototype.toString.call(params), "[object URLSearchParams]");
    assert.equal(Object.prototype.toString.call(params.entries()), "[object URLSearchParams Iterator]");
    assert.equal(Object.getOwnPropertyDescriptor(URLSearchParams.prototype, Symbol.iterator).enumerable, false);
    assert.throws(() => URLSearchParams("a=1"), TypeError);
  });

  test("subclassing uses new.target structure", () => {
    class CustomSearchParams extends URLSearchParams {}
    const custom = new CustomSearchParams("a=1&a=2");
    assert(custom instanceof CustomSearchParams);
    assert(custom instanceof URLSearchParams);
    assert.equal(Object.getPrototypeOf(custom), CustomSearchParams.prototype);
    custom.append("b", "3");
    assert.deepEqual(Array.from(custom), [["a", "1"], ["a", "2"], ["b", "3"]]);
  });

  test("USVString conversion covers strings iterables records and methods", () => {
    assert.deepEqual(Array.from(new URLSearchParams("a=\uD800&\uDC00=b")), [["a", "�"], ["�", "b"]]);
    assert.equal(new URLSearchParams("a=\uD800&\uDC00=b").toString(), "a=%EF%BF%BD&%EF%BF%BD=b");
    assert.deepEqual(Array.from(new URLSearchParams([["a\uD800", "1\uDFFF"]])), [["a�", "1�"]]);

    const duplicateLead = {};
    duplicateLead["\uD835x"] = "1";
    duplicateLead.xx = "2";
    duplicateLead["\uD83Dx"] = "3";
    assert.deepEqual(Array.from(new URLSearchParams(duplicateLead)), [["�x", "3"], ["xx", "2"]]);

    const duplicateTrail = {};
    duplicateTrail["x\uDC53"] = "1";
    duplicateTrail["x\uDC5C"] = "2";
    duplicateTrail["x\uDC65"] = "3";
    assert.deepEqual(Array.from(new URLSearchParams(duplicateTrail)), [["x�", "3"]]);

    const mixed = { "a\0b": "42", "c\uD83D": "23", "d\u1234": "foo" };
    assert.deepEqual(Array.from(new URLSearchParams(mixed)), [["a\0b", "42"], ["c�", "23"], ["d\u1234", "foo"]]);

    const params = new URLSearchParams();
    params.append("a\uD800", "b\uDC00");
    assert.deepEqual(Array.from(params), [["a�", "b�"]]);
    assert.equal(params.has("a\uDFFF", "b\uD800"), true);
    assert.equal(params.get("a\uDC00"), "b�");
    params.set("a\uD800", "c\uDC00");
    assert.deepEqual(params.getAll("a\uDFFF"), ["c�"]);
    params.delete("a\uD800", "c\uDC00");
    assert.equal(params.size, 0);
  });

  test("size and toJSON preserve repeated keys", () => {
    const empty = new URLSearchParams();
    assert.equal("length" in empty, false);
    assert.equal(empty.size, 0);
    assert.deepEqual(empty.toJSON(), {});
    assert.equal(JSON.stringify(empty), "{}");

    const params = new URLSearchParams("a=1&b=2&a=3&empty=");
    assert.equal(params.size, 4);
    assert.deepEqual(params.toJSON(), { a: ["1", "3"], b: "2", empty: "" });
    assert.equal(JSON.stringify(params), '{"a":["1","3"],"b":"2","empty":""}');
    const tagged = params.toJSON();
    assert.equal(Object.prototype.toString.call(tagged), "[object URLSearchParams]");
    assert.equal(Object.getOwnPropertyDescriptor(tagged, Symbol.toStringTag).enumerable, false);

    params.append("b", "4");
    assert.deepEqual(params.toJSON(), { a: ["1", "3"], b: ["2", "4"], empty: "" });
    assert.throws(() => URLSearchParams.prototype.toJSON.call({}), TypeError);

    const many = new URLSearchParams();
    for (let index = 0; index < 256; index++)
      many.append(`k${index}`, `${index}`);
    many.append("k7", "again");
    const json = many.toJSON();
    assert.equal(Object.keys(json).length, 256);
    assert.equal(json.k0, "0");
    assert.deepEqual(json.k7, ["7", "again"]);
    assert.equal(json.k255, "255");
  });
});
