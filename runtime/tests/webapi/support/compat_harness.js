export const isWindows = false;
export const isMacOS = false;
export const isLinux = true;

export function delay(ms = 0) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

export async function flushAsyncEvents() {
  await delay(0);
  await delay(0);
  await delay(0);
  await delay(0);
}

export function readableStreamFromArray(array) {
  return new ReadableStream({
    start(controller) {
      for (const entry of array) {
        controller.enqueue(entry);
      }
      controller.close();
    },
  });
}

export async function readableStreamToArray(stream) {
  const array = [];
  const reader = stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      array.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  return array;
}

export function concatUint8(chunks) {
  let byteLength = 0;
  for (const chunk of chunks) {
    if (!(chunk instanceof Uint8Array)) {
      throw new TypeError("expected Uint8Array stream chunk");
    }
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

export async function readableStreamToBytes(stream) {
  return concatUint8(await readableStreamToArray(stream));
}

export async function readableStreamToArrayBuffer(stream) {
  const bytes = await readableStreamToBytes(stream);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

export async function readableStreamToText(stream) {
  const chunks = await readableStreamToArray(stream);
  let text = "";
  const decoder = new TextDecoder();
  for (const chunk of chunks) {
    if (typeof chunk === "string") {
      text += chunk;
      continue;
    }
    if (chunk instanceof Uint8Array) {
      text += decoder.decode(chunk, { stream: true });
      continue;
    }
    if (chunk instanceof ArrayBuffer) {
      text += decoder.decode(new Uint8Array(chunk), { stream: true });
      continue;
    }
    if (ArrayBuffer.isView(chunk)) {
      text += decoder.decode(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength), { stream: true });
      continue;
    }
    throw new TypeError("unsupported ReadableStream text chunk");
  }
  return text + decoder.decode();
}

export const collectBytes = readableStreamToBytes;

export function makeWeakRefs(count, factory) {
  const refs = [];
  for (let index = 0; index < count; index++) {
    let value = factory(index);
    refs.push(new WeakRef(value));
    value = null;
  }
  return refs;
}

export function weakRecord(label, refs, maxLive = 4) {
  if (typeof WeakRef !== "function") {
    throw new TypeError("WeakRef must exist for retention tests");
  }
  return { label, refs, maxLive };
}

export function expectLeakRecordsCollected(records) {
  const checker = globalThis.expectLeakRecordsCollected;
  if (typeof checker !== "function") {
    throw new Error("leak checks require runCompatLeakSuite or runLeakSuite");
  }
  return checker(records);
}
