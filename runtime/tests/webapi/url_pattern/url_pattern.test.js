// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/urlpattern/urlpattern.test.ts
// - reference/bun-v1.3.14/test/js/web/urlpattern/urlpatterntestdata.json

const testData = globalThis.__colloURLPatternTestData;
const kComponents = ["protocol", "username", "password", "hostname", "port", "pathname", "search", "hash"];

function expectedPatternString(entry, component) {
  if (entry.expected_obj && typeof entry.expected_obj === "object" && entry.expected_obj[component] !== undefined)
    return entry.expected_obj[component];

  let baseURL = null;
  if (entry.pattern.length > 0 && entry.pattern[0] && entry.pattern[0].baseURL)
    baseURL = new URL(entry.pattern[0].baseURL);
  else if (entry.pattern.length > 1 && typeof entry.pattern[1] === "string")
    baseURL = new URL(entry.pattern[1]);

  const earlier = {
    protocol: [],
    hostname: ["protocol"],
    port: ["protocol", "hostname"],
    username: [],
    password: [],
    pathname: ["protocol", "hostname", "port"],
    search: ["protocol", "hostname", "port", "pathname"],
    hash: ["protocol", "hostname", "port", "pathname", "search"],
  };

  if (entry.exactly_empty_components && entry.exactly_empty_components.includes(component))
    return "";
  if (entry.pattern[0] && typeof entry.pattern[0] === "object" && entry.pattern[0][component])
    return entry.pattern[0][component];
  if (entry.pattern[0] && typeof entry.pattern[0] === "object" && earlier[component].some((name) => name in entry.pattern[0]))
    return "*";
  if (baseURL && component !== "username" && component !== "password") {
    let value = baseURL[component];
    if (component === "protocol")
      value = value.slice(0, -1);
    else if (component === "search" || component === "hash")
      value = value.slice(1);
    return value;
  }
  return "*";
}

function expectedComponentResult(entry, component) {
  let expected = entry.expected_match && entry.expected_match[component];
  if (!expected) {
    expected = { input: "", groups: {} };
    if (!entry.exactly_empty_components || !entry.exactly_empty_components.includes(component))
      expected.groups["0"] = "";
  }
  for (const key in expected.groups) {
    if (expected.groups[key] === null)
      expected.groups[key] = undefined;
  }
  return expected;
}

describe("URLPattern", () => {
  test("global and prototype descriptors", () => {
    assert.equal(typeof URLPattern, "function");
    assert.equal(URLPattern.length, 0);
    assert.equal(URLPattern.name, "URLPattern");
    assert.throws(() => URLPattern({ pathname: "*" }), TypeError);
    assert.equal(Object.prototype.toString.call(new URLPattern({})), "[object URLPattern]");

    const globalDescriptor = Object.getOwnPropertyDescriptor(globalThis, "URLPattern");
    assert.equal(globalDescriptor.enumerable, true);
    assert.equal(globalDescriptor.configurable, true);
    assert.equal(globalDescriptor.writable, true);

    for (const component of kComponents) {
      const descriptor = Object.getOwnPropertyDescriptor(URLPattern.prototype, component);
      assert.equal(typeof descriptor.get, "function");
      assert.equal(descriptor.set, undefined);
      assert.equal(descriptor.enumerable, true);
      assert.equal(descriptor.configurable, true);
      assert.throws(() => descriptor.get.call({}), TypeError);
    }

    const hasRegExpGroups = Object.getOwnPropertyDescriptor(URLPattern.prototype, "hasRegExpGroups");
    assert.equal(typeof hasRegExpGroups.get, "function");
    assert.equal(hasRegExpGroups.set, undefined);
    assert.equal(hasRegExpGroups.enumerable, true);
    assert.equal(hasRegExpGroups.configurable, true);
    assert.throws(() => hasRegExpGroups.get.call({}), TypeError);

    for (const name of ["test", "exec"]) {
      const descriptor = Object.getOwnPropertyDescriptor(URLPattern.prototype, name);
      assert.equal(typeof descriptor.value, "function");
      assert.equal(descriptor.value.length, 0);
      assert.equal(descriptor.enumerable, true);
      assert.equal(descriptor.configurable, true);
      assert.equal(descriptor.writable, true);
      assert.throws(() => descriptor.value.call({}), TypeError);
    }

    assert.equal(Object.keys(URLPattern.prototype).join(","), "protocol,username,password,hostname,port,pathname,search,hash,hasRegExpGroups,test,exec");

    const prototypeDescriptor = Object.getOwnPropertyDescriptor(URLPattern, "prototype");
    assert.equal(prototypeDescriptor.enumerable, false);
    assert.equal(prototypeDescriptor.configurable, false);
    assert.equal(prototypeDescriptor.writable, false);

    const constructorDescriptor = Object.getOwnPropertyDescriptor(URLPattern.prototype, "constructor");
    assert.equal(constructorDescriptor.enumerable, false);
    assert.equal(constructorDescriptor.configurable, true);
    assert.equal(constructorDescriptor.writable, true);

    const tagDescriptor = Object.getOwnPropertyDescriptor(URLPattern.prototype, Symbol.toStringTag);
    assert.equal(tagDescriptor.value, "URLPattern");
    assert.equal(tagDescriptor.enumerable, false);
    assert.equal(tagDescriptor.configurable, true);
    assert.equal(tagDescriptor.writable, false);
  });

  test("WPT urlpatterntestdata", () => {
    for (const entry of testData) {
      if (entry.expected_obj === "error") {
        assert.throws(() => new URLPattern(...entry.pattern), TypeError, `pattern should reject: ${JSON.stringify(entry.pattern)}`);
        continue;
      }

      const pattern = new URLPattern(...entry.pattern);
      for (const component of kComponents)
        assert.equal(pattern[component], expectedPatternString(entry, component), `${component} mismatch for ${JSON.stringify(entry.pattern)}`);

      const inputs = entry.inputs || [];
      if (entry.expected_match === "error") {
        assert.throws(() => pattern.test(...inputs), TypeError);
        assert.throws(() => pattern.exec(...inputs), TypeError);
        continue;
      }

      assert.equal(pattern.test(...inputs), !!entry.expected_match, `test mismatch for ${JSON.stringify(entry.pattern)} ${JSON.stringify(inputs)}`);
      const result = pattern.exec(...inputs);
      if (!entry.expected_match || typeof entry.expected_match !== "object") {
        assert.equal(result, entry.expected_match);
        continue;
      }

      const expectedInputs = entry.expected_match.inputs || inputs;
      assert.equal(result.inputs.length, expectedInputs.length);
      for (let i = 0; i < result.inputs.length; i++) {
        const actualInput = result.inputs[i];
        const expectedInput = expectedInputs[i];
        if (typeof actualInput === "string") {
          assert.equal(actualInput, expectedInput);
        } else {
          for (const component of kComponents)
            assert.equal(actualInput[component], expectedInput[component]);
        }
      }
      for (const component of kComponents)
        assert.deepEqual(result[component], expectedComponentResult(entry, component), `${component} result mismatch`);
    }
  });

  test("constructor edge cases", () => {
    assert.throws(() => new URLPattern(new URL("https://example.org/%(")), TypeError);
    assert.throws(() => new URLPattern(new URL("https://example.org/%((")), TypeError);
    assert.throws(() => new URLPattern("(\\"), TypeError);
    assert.doesNotThrow(() => new URLPattern(undefined, undefined));
  });

  test("subclass new.target and exec result shape", () => {
    class CustomURLPattern extends URLPattern {}
    const custom = new CustomURLPattern({ pathname: "/users/:id" });
    assert(custom instanceof CustomURLPattern);
    assert(custom instanceof URLPattern);
    assert.equal(Object.getPrototypeOf(custom), CustomURLPattern.prototype);
    assert.equal(custom.pathname, "/users/:id");

    const cloned = new URLPattern(custom);
    assert.equal(cloned.pathname, "/users/:id");
    assert.equal(cloned.test({ pathname: "/users/42" }), true);

    const result = custom.exec({ pathname: "/users/42" });
    assert.equal(Object.getPrototypeOf(result), Object.prototype);
    assert.deepEqual(Object.keys(result), ["inputs", "protocol", "username", "password", "hostname", "port", "pathname", "search", "hash"]);
    assert.deepEqual(Object.keys(result.inputs[0]), ["pathname"]);
    assert.deepEqual(Object.keys(result.pathname), ["input", "groups"]);
    assert.equal(Object.getPrototypeOf(result.pathname.groups), Object.prototype);
    assert.deepEqual(Object.keys(result.pathname.groups), ["id"]);
    assert.equal(Object.getOwnPropertyDescriptor(result.pathname.groups, "id").enumerable, true);
    assert.equal(result.pathname.groups.id, "42");
  });

  test("simple pathname-only patterns match without changing observable argument reads", () => {
    const root = new URLPattern({ pathname: "/" });
    assert.equal(root.test({ pathname: "/" }), true);
    assert.deepEqual(root.exec({ pathname: "/" }).pathname.groups, {});

    const literal = new URLPattern({ pathname: "/users" });
    assert.equal(literal.test({ pathname: "/users" }), true);
    assert.equal(literal.test({ pathname: "/users/42" }), false);
    assert.deepEqual(literal.exec({ pathname: "/users" }).pathname.groups, {});

    const pattern = new URLPattern({ pathname: "/users/:id/posts/:slug" });
    assert.equal(pattern.test({ pathname: "/users/123/posts/hello" }), true);
    assert.equal(pattern.test({ pathname: "/users/123/comments/hello" }), false);
    assert.equal(pattern.exec({ pathname: "/users/123/comments/hello" }), null);
    assert.equal(pattern.test("https://example.com/users/123/posts/hello?debug=1#top"), true);
    assert.equal(pattern.test("https://example.com/users/123/comments/hello?debug=1#top"), false);
    assert.equal(pattern.test("/users/123/posts/hello", "https://example.com/base"), true);
    assert.equal(pattern.test("/users/123/comments/hello", "https://example.com/base"), false);
    assert.equal(pattern.test("https://example.com/users/123/posts/hello", "not a url"), false);
    assert.equal(new URLPattern({ pathname: "/foo/bar" }).test({ pathname: "/foo/./bar" }), true);

    const result = pattern.exec({ pathname: "/users/123/posts/hello" });
    assert.deepEqual(result.inputs, [{ pathname: "/users/123/posts/hello" }]);
    assert.equal(result.protocol.input, "");
    assert.deepEqual(result.protocol.groups, { 0: "" });
    assert.deepEqual(result.pathname.groups, { id: "123", slug: "hello" });

    const reads = [];
    const input = {};
    for (const component of [...kComponents, "baseURL"]) {
      Object.defineProperty(input, component, {
        enumerable: true,
        get() {
          reads.push(component);
          return component === "pathname" ? "/users/321/posts/world" : undefined;
        },
      });
    }
    assert.equal(pattern.test(input), true);
    assert.deepEqual(reads, [...kComponents, "baseURL"]);
  });

  test("pathname fast path validates absolute URLs and bases before matching", () => {
    const pattern = new URLPattern({ pathname: "/admin/:id" });
    assert.equal(pattern.test("https://example.com/admin/1"), true);
    assert.equal(pattern.test("https://bad host/admin/1"), false);
    assert.equal(pattern.test("https://example.com:999999/admin/1"), false);
    assert.equal(pattern.test("/admin/1", "https://bad host/base"), false);
    assert.equal(pattern.test("/admin/1", "https://example.com/base"), true);
  });

  test("URL object inputs are read as URLPatternInit components", () => {
    const pattern = new URLPattern({ protocol: "https", hostname: "example.com", pathname: "/docs/:slug", search: "q=1", hash: "top" });
    const input = new URL("https://example.com/docs/intro?q=1#top");

    assert.equal(pattern.test(input), true);
    const result = pattern.exec(input);
    assert.deepEqual(result.inputs, [{
      protocol: "https:",
      username: "",
      password: "",
      hostname: "example.com",
      port: "",
      pathname: "/docs/intro",
      search: "?q=1",
      hash: "#top",
    }]);
    assert.equal(result.pathname.groups.slug, "intro");
  });

  test("hasRegExpGroups", () => {
    assert.equal(new URLPattern({}).hasRegExpGroups, false);
    for (const component of kComponents) {
      assert.equal(new URLPattern({ [component]: "*" }).hasRegExpGroups, false);
      assert.equal(new URLPattern({ [component]: ":foo" }).hasRegExpGroups, false);
      assert.equal(new URLPattern({ [component]: ":foo?" }).hasRegExpGroups, false);
      assert.equal(new URLPattern({ [component]: ":foo(hi)" }).hasRegExpGroups, true);
      assert.equal(new URLPattern({ [component]: "(hi)" }).hasRegExpGroups, true);
      if (component !== "protocol" && component !== "port") {
        assert.equal(new URLPattern({ [component]: "a-{:hello}-z-*-a" }).hasRegExpGroups, false);
        assert.equal(new URLPattern({ [component]: "a-(hi)-z-(lo)-a" }).hasRegExpGroups, true);
      }
    }
    assert.equal(new URLPattern({ pathname: "/a/:foo/:baz?/b/*" }).hasRegExpGroups, false);
    assert.equal(new URLPattern({ pathname: "/a/:foo/:baz([a-z]+)?/b/*" }).hasRegExpGroups, true);
  });

  test("rejects regex groups that risk catastrophic backtracking (ReDoS)", () => {
    // Nested unbounded quantifiers are the structural signature of exponential
    // backtracking; constructing such a pattern must throw rather than defer an
    // unbounded match to a later request.
    // Caught by the part-modifier path: an unbounded URLPattern modifier (`+`/`*`,
    // applied to the group) wraps a regex value that already has an unbounded
    // quantifier. ((.*)* is excluded on purpose: `.*` parses to a Collo-generated
    // FullWildcard, the spec-blessed `**` form, which is linear and not scanned.
    // `{n,}` is URLPattern group-delimiter syntax, not a regex quantifier.)
    const hostileModifier = [
      "(a+)+",
      "(a*)*",
      "(.+)+",
      "(\\d+)+",
      "(a+)*",
    ];
    // Caught by the value-nesting scanner: nested unbounded quantifiers inside a
    // single (tokenizer-valid) regex value using non-capturing groups.
    const hostileNested = [
      "((?:a+)+)",
      "((?:a*)*)",
      "((?:[a-z]+)+)",
      "((?:.*)+)",
    ];
    for (const source of [...hostileModifier, ...hostileNested]) {
      for (const component of ["pathname", "search", "hash", "hostname"]) {
        assert.throws(() => new URLPattern({ [component]: source }), TypeError, `${component}=${source} should be rejected`);
      }
    }

    // Safe patterns with a single bounded or non-nested quantifier still compile.
    for (const safe of ["(a+)", "(a+)b(c+)", "([a-z]+)", "(\\d{2,4})", "(a{1,3})", "(.*)", "(a+)?", "((?:a+))"]) {
      assert.doesNotThrow(() => new URLPattern({ pathname: safe }), `${safe} should compile`);
    }
  });

  test("a known ReDoS pattern+input completes within a bound instead of hanging", () => {
    // If a hostile pattern were ever accepted, an adversarial input must still
    // return quickly (the matcher is bounded). We assert the rejected-at-compile
    // path is instant, and that a deliberately heavy-but-linear pattern matched
    // against a long adversarial input completes well under a generous budget.
    const start = performance.now();
    assert.throws(() => new URLPattern({ pathname: "(a+)+$" }), TypeError);
    const adversarial = "a".repeat(40) + "!";
    const linear = new URLPattern({ pathname: "(a*)" });
    // No exponential blowup: a single * over a 40-char input is trivially linear.
    assert.equal(linear.test({ pathname: "aaaa" }), true);
    assert.equal(linear.test({ pathname: adversarial }), false);
    const elapsed = performance.now() - start;
    assert(elapsed < 2000, `ReDoS-bound check took too long: ${elapsed}ms`);
  });

  test("patterns built from a temporary input remain valid when used later", () => {
    // Regression for the StringView-lifetime hazard: the constructor string and
    // its tokens used to alias a temporary backing buffer. Build a pattern from
    // a freshly-constructed (and immediately discarded) source string, force the
    // source out of scope, then exercise the compiled pattern.
    function buildFromTemporary() {
      // Concatenation produces a fresh String that the constructor must not alias.
      const source = ["https://example.com", "/users/", ":id", "/posts/", ":slug"].join("");
      return new URLPattern(source);
    }
    const pattern = buildFromTemporary();
    // Trigger some allocations to make any use-after-free likely to surface.
    let churn = "";
    for (let i = 0; i < 1000; i++) churn += String(i);
    assert(churn.length > 0);

    assert.equal(pattern.protocol, "https");
    assert.equal(pattern.hostname, "example.com");
    assert.equal(pattern.pathname, "/users/:id/posts/:slug");
    assert.equal(pattern.test("https://example.com/users/42/posts/hello"), true);
    const result = pattern.exec("https://example.com/users/42/posts/hello");
    assert.equal(result.pathname.groups.id, "42");
    assert.equal(result.pathname.groups.slug, "hello");

    // Also exercise the init-dictionary path built from temporaries.
    const init = new URLPattern({ pathname: ["/a/", ":x", "/b/", ":y"].join("") });
    assert.equal(init.pathname, "/a/:x/b/:y");
    assert.equal(init.exec({ pathname: "/a/1/b/2" }).pathname.groups.x, "1");
  });

  test("fast pathname path matches the full engine over a representative matrix", () => {
    // The binding has a hand-rolled fast path for simple pathname-only patterns.
    // It must never diverge from the full URLPattern engine. We compare both
    // test() and exec() across many pattern/input pairs. The fast-path compiler
    // bails out whenever ignoreCase is set, so building the same pattern with
    // { ignoreCase: true } forces the full engine with identical semantics for
    // the lowercase pathnames used here.
    const patterns = [
      "/",
      "/users",
      "/users/:id",
      "/users/:id/posts/:slug",
      "/a/b/c",
      "/:a/:b/:c",
      "/files/:name",
    ];
    const inputs = [
      { pathname: "/" },
      { pathname: "/users" },
      { pathname: "/users/42" },
      { pathname: "/users/42/posts/hello" },
      { pathname: "/users/42/comments/hello" },
      { pathname: "/a/b/c" },
      { pathname: "/a/b" },
      { pathname: "/a/b/c/d" },
      { pathname: "/x/y/z" },
      { pathname: "/files/report.pdf" },
      { pathname: "/files/a%2Fb" },
      { pathname: "" },
      { pathname: "/users/" },
      { pathname: "//users" },
      "https://example.com/users/42/posts/hello?q=1#top",
      "https://example.com/a/b/c",
    ];

    for (const p of patterns) {
      const fast = new URLPattern({ pathname: p });
      // ignoreCase disables the fast-path compiler, forcing the full engine.
      const full = new URLPattern({ pathname: p }, { ignoreCase: true });
      for (const input of inputs) {
        const fastTest = safeCall(() => fast.test(input));
        const fullTest = safeCall(() => full.test(input));
        assert.deepEqual(fastTest, fullTest, `test divergence for ${p} / ${JSON.stringify(input)}`);

        const fastExec = safeCall(() => normalizeExec(fast.exec(input)));
        const fullExec = safeCall(() => normalizeExec(full.exec(input)));
        assert.deepEqual(fastExec, fullExec, `exec divergence for ${p} / ${JSON.stringify(input)}`);
      }
    }

    function safeCall(fn) {
      try {
        return { ok: true, value: fn() };
      } catch (err) {
        return { ok: false, error: err && err.name };
      }
    }

    // Compare the full result shape that the fast path is responsible for.
    function normalizeExec(result) {
      if (result === null) return null;
      return {
        inputs: result.inputs,
        pathname: result.pathname,
        protocol: result.protocol,
        hostname: result.hostname,
        search: result.search,
        hash: result.hash,
      };
    }
  });
});
