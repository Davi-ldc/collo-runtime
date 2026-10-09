// Collo-only.

bench("message-channel.create-close", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const channel = new MessageChannel();
    checksum += channel.port1 instanceof MessagePort;
    channel.port1.close();
    channel.port2.close();
  }
  return checksum;
}, { iterations: 50000, warmup: 1000 });

bench("message-port.ref-unref-hasref", iterations => {
  const channel = new MessageChannel();
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    channel.port1.ref();
    checksum += channel.port1.hasRef();
    channel.port1.unref();
    checksum += channel.port1.hasRef();
  }
  channel.port1.close();
  channel.port2.close();
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("message-channel.post-buffered-start", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const channel = new MessageChannel();
    const done = new Promise(resolve => {
      channel.port2.onmessage = event => {
        checksum += event.data;
        channel.port1.close();
        channel.port2.close();
        resolve();
      };
    });
    channel.port1.postMessage(1);
    await done;
  }
  return checksum;
}, { iterations: 1000, warmup: 50 });

bench("message-channel.transfer-arraybuffer", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const channel = new MessageChannel();
    const buffer = new ArrayBuffer(16);
    new Uint8Array(buffer)[0] = 7;
    const done = new Promise(resolve => {
      channel.port2.onmessage = event => {
        checksum += new Uint8Array(event.data)[0];
        channel.port1.close();
        channel.port2.close();
        resolve();
      };
    });
    channel.port1.postMessage(buffer, [buffer]);
    await done;
  }
  return checksum;
}, { iterations: 1000, warmup: 50 });

bench("message-channel.transfer-port", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const channel = new MessageChannel();
    const carried = new MessageChannel();
    const done = new Promise(resolve => {
      channel.port2.onmessage = event => {
        checksum += event.ports[0] instanceof MessagePort;
        event.ports[0].close();
        carried.port2.close();
        channel.port1.close();
        channel.port2.close();
        resolve();
      };
    });
    channel.port1.postMessage({ port: carried.port1 }, [carried.port1]);
    await done;
  }
  return checksum;
}, { iterations: 1000, warmup: 50 });
