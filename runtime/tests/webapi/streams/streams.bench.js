// Collo-only.

bench("ReadableStream read queued chunks", async iterations => {
  let checksum = 0;
  for (let index = 0; index < iterations; index++) {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(index & 255);
        controller.close();
      },
    });
    const reader = stream.getReader();
    const result = await reader.read();
    checksum += result.value;
  }
  return checksum;
}, { iterations: 1000, warmup: 100 });

bench("Blob.stream read bytes", async iterations => {
  let checksum = 0;
  const decoder = new TextDecoder();
  for (let index = 0; index < iterations; index++) {
    const reader = new Blob(["abc"]).stream().getReader();
    const result = await reader.read();
    checksum += decoder.decode(result.value).length;
  }
  return checksum;
}, { iterations: 1000, warmup: 100 });

bench("Response.body tee read bytes", async iterations => {
  let checksum = 0;
  for (let index = 0; index < iterations; index++) {
    const [left, right] = new Response(new Uint8Array([1, 2, 3, index & 255])).body.tee();
    const leftChunk = (await left.getReader().read()).value;
    const rightChunk = (await right.getReader().read()).value;
    checksum += leftChunk[0] + rightChunk[3];
  }
  return checksum;
}, { iterations: 1000, warmup: 100 });

bench("ReadableStream pipeTo highWaterMark", async iterations => {
  let checksum = 0;
  for (let index = 0; index < iterations; index++) {
    const readable = new ReadableStream({
      start(controller) {
        controller.enqueue(index & 255);
        controller.enqueue((index + 1) & 255);
        controller.close();
      },
    });
    const writable = new WritableStream(
      {
        write(chunk) {
          checksum += chunk;
        },
      },
      { highWaterMark: 2 },
    );
    await readable.pipeTo(writable);
  }
  return checksum;
}, { iterations: 1000, warmup: 100 });
