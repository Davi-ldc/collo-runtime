// Collo-only.

bench("ReadableStream CountQueuingStrategy enqueue accounting", async iterations => {
  let checksum = 0;
  for (let index = 0; index < iterations; index++) {
    let controller;
    const stream = new ReadableStream(
      {
        start(value) {
          controller = value;
        },
      },
      new CountQueuingStrategy({ highWaterMark: 4 }),
    );
    controller.enqueue(index);
    checksum += controller.desiredSize;
    controller.close();
    await stream.getReader().read();
  }
  return checksum;
}, { iterations: 1000, warmup: 100 });

bench("WritableStream ByteLengthQueuingStrategy write accounting", async iterations => {
  let checksum = 0;
  const chunk = new Uint8Array(16);
  for (let index = 0; index < iterations; index++) {
    const stream = new WritableStream(
      {
        write(value) {
          checksum += value.byteLength;
        },
      },
      new ByteLengthQueuingStrategy({ highWaterMark: 64 }),
    );
    const writer = stream.getWriter();
    await writer.write(chunk);
    checksum += writer.desiredSize;
  }
  return checksum;
}, { iterations: 1000, warmup: 100 });
