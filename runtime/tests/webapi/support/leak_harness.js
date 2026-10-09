const __colloWebApiLeakTests = [];
let __colloWebApiLeakPrefix = "";
let __colloWebApiLeakRecord = null;

function leakTest(name, setup, check) {
  const fullName = __colloWebApiLeakPrefix ? `${__colloWebApiLeakPrefix} ${name}` : String(name);
  __colloWebApiLeakTests.push({ name: fullName, setup, check });
}

function describeLeaks(name, fn) {
  const previous = __colloWebApiLeakPrefix;
  __colloWebApiLeakPrefix = previous ? `${previous} ${name}` : String(name);
  try {
    fn();
  } finally {
    __colloWebApiLeakPrefix = previous;
  }
}

function __colloLeakLiveWeakRefCount(refs) {
  let live = 0;
  for (const ref of refs) {
    if (ref.deref() !== undefined) live++;
  }
  return live;
}

function expectLeakRecordsCollected(records) {
  for (const record of records) {
    const live = __colloLeakLiveWeakRefCount(record.refs);
    const maxLive = record.maxLive ?? 4;
    if (live > maxLive)
      throw new Error(`${record.label} retained ${live} objects`);
  }
}

function __colloMakeWeakRefs(count, factory) {
  const refs = [];
  for (let index = 0; index < count; index++) {
    let value = factory(index);
    refs.push(new WeakRef(value));
    value = null;
  }
  return refs;
}

function __colloWeakRecord(label, refs, maxLive = 4) {
  if (typeof WeakRef !== "function")
    throw new TypeError("WeakRef must exist for retention tests");
  return { label, refs, maxLive };
}

function __colloConcatUint8(chunks) {
  let byteLength = 0;
  for (const chunk of chunks) {
    if (!(chunk instanceof Uint8Array))
      throw new TypeError("expected Uint8Array stream chunk");
    byteLength += chunk.byteLength;
  }

  const bytes = new Uint8Array(byteLength);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

async function __colloCollectBytes(stream) {
  const chunks = [];
  const reader = stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  return __colloConcatUint8(chunks);
}

async function __colloLeakSettleBeforeCheckpoint() {
  for (let index = 0; index < 4; index++) {
    await Promise.resolve();
  }
  await new Promise(resolve => setTimeout(resolve, 0));
}

function __colloWebApiLeakTestCount() {
  return __colloWebApiLeakTests.length;
}

async function __colloRunWebApiLeakSetup(index) {
  __colloWebApiLeakRecord = null;
  const entry = __colloWebApiLeakTests[index];
  if (!entry) {
    return {
      ok: false,
      total: __colloWebApiLeakTests.length,
      failures: [{ name: `leak test ${index}`, message: "unknown leak test index" }],
    };
  }

  try {
    const state = await entry.setup();
    await __colloLeakSettleBeforeCheckpoint();
    __colloWebApiLeakRecord = { name: entry.name, check: entry.check, state };
  } catch (err) {
    return {
      ok: false,
      total: __colloWebApiLeakTests.length,
      failures: [{
        name: entry.name,
        message: __colloErrorText(err).slice(0, 700),
      }],
    };
  }
  return {
    ok: true,
    total: __colloWebApiLeakTests.length,
    failures: [],
  };
}

async function __colloRunWebApiLeakChecks() {
  const failures = [];
  const entry = __colloWebApiLeakRecord;

  if (!entry) {
    failures.push({ name: "leak checkpoint", message: "missing leak setup record" });
  } else {
    try {
      await entry.check(entry.state);
    } catch (err) {
      failures.push({
        name: entry.name,
        message: __colloErrorText(err).slice(0, 700),
      });
    }
  }

  __colloWebApiLeakRecord = null;
  return {
    ok: failures.length === 0,
    total: __colloWebApiLeakTests.length,
    failures: failures.slice(0, 1),
  };
}

globalThis.leakTest = leakTest;
globalThis.describeLeaks = describeLeaks;
globalThis.expectLeakRecordsCollected = expectLeakRecordsCollected;
globalThis.makeWeakRefs = __colloMakeWeakRefs;
globalThis.weakRecord = __colloWeakRecord;
globalThis.collectBytes = __colloCollectBytes;
globalThis.__colloWebApiLeakTestCount = __colloWebApiLeakTestCount;
globalThis.__colloRunWebApiLeakSetup = __colloRunWebApiLeakSetup;
globalThis.__colloRunWebApiLeakChecks = __colloRunWebApiLeakChecks;
