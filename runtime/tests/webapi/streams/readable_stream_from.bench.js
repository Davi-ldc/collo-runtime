bench("ReadableStream.from sync array drain", async () => {
  const input = Array.from({ length: 128 }, (_, index) => index);
  const reader = ReadableStream.from(input).getReader();
  let sum = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    sum += value;
  }
  assert.equal(sum, 8128);
});

bench("ReadableStream.from async iterable drain", async () => {
  let value = 0;
  const iterable = {
    async next() {
      if (value === 128) return { done: true };
      return { value: value++, done: false };
    },
    [Symbol.asyncIterator]() {
      return this;
    },
  };
  const reader = ReadableStream.from(iterable).getReader();
  let sum = 0;
  while (true) {
    const result = await reader.read();
    if (result.done) break;
    sum += result.value;
  }
  assert.equal(sum, 8128);
});
