// Leak coverage derived from Bun v1.3.14 intent:
// - reference/bun-v1.3.14/test/js/web/workers/message-port-context-destroy-leak.test.ts
// - reference/bun-v1.3.14/test/js/web/workers/message-port-closed-leak.test.ts
// - reference/bun-v1.3.14/test/js/web/broadcastchannel/message-event-init-gc.test.ts

describeLeaks("MessageChannel MessagePort and MessageEvent retention", () => {
  leakTest(
    "dropped entangled MessagePorts with handlers are collectable",
    () => {
      const channelRefs = [];
      const portRefs = [];

      for (let index = 0; index < 256; index++) {
        let channel = new MessageChannel();
        channel.port1.onmessage = () => {};
        channel.port2.addEventListener("message", () => {});
        channel.port1.ref();
        channel.port1.unref();
        channelRefs.push(new WeakRef(channel));
        portRefs.push(new WeakRef(channel.port1));
        portRefs.push(new WeakRef(channel.port2));
        channel = null;
      }

      return [
        weakRecord("dropped MessageChannel", channelRefs, 16),
        weakRecord("dropped MessagePort", portRefs, 16),
      ];
    },
    expectLeakRecordsCollected,
  );

  leakTest(
    "MessageEvent source and ports are collectable after the event is dropped",
    () => {
      const eventRefs = [];
      const portRefs = [];

      for (let index = 0; index < 256; index++) {
        let channel = new MessageChannel();
        let event = new MessageEvent("message", {
          data: { index },
          source: channel.port1,
          ports: [channel.port2],
        });
        eventRefs.push(new WeakRef(event));
        portRefs.push(new WeakRef(channel.port1));
        portRefs.push(new WeakRef(channel.port2));
        event = null;
        channel = null;
      }

      return [
        weakRecord("dropped MessageEvent", eventRefs, 16),
        weakRecord("MessageEvent retained ports", portRefs, 16),
      ];
    },
    expectLeakRecordsCollected,
  );

  leakTest(
    "initMessageEvent replacement does not keep previous data source or ports alive",
    () => {
      const dataRefs = [];
      const portRefs = [];
      const eventRefs = [];

      for (let index = 0; index < 256; index++) {
        let channel = new MessageChannel();
        let data = { index, payload: new ArrayBuffer(1024) };
        let event = new MessageEvent("message", {
          data,
          source: channel.port1,
          ports: [channel.port2],
        });
        event.initMessageEvent("message", false, false, null, "", "", null, []);
        dataRefs.push(new WeakRef(data));
        portRefs.push(new WeakRef(channel.port1));
        portRefs.push(new WeakRef(channel.port2));
        eventRefs.push(new WeakRef(event));
        data = null;
        event = null;
        channel = null;
      }

      return [
        weakRecord("replaced MessageEvent data", dataRefs, 16),
        weakRecord("replaced MessageEvent ports", portRefs, 16),
        weakRecord("reinitialized MessageEvent", eventRefs, 16),
      ];
    },
    expectLeakRecordsCollected,
  );

  leakTest(
    "closed MessagePort endpoints do not keep dropped channel objects alive",
    () => {
      const channelRefs = [];
      const portRefs = [];

      for (let index = 0; index < 256; index++) {
        let channel = new MessageChannel();
        channel.port2.close();
        for (let message = 0; message < 8; message++)
          channel.port1.postMessage({ index, message });
        channel.port1.close();
        channelRefs.push(new WeakRef(channel));
        portRefs.push(new WeakRef(channel.port1));
        portRefs.push(new WeakRef(channel.port2));
        channel = null;
      }

      return [
        weakRecord("closed MessageChannel", channelRefs, 16),
        weakRecord("closed MessagePort", portRefs, 16),
      ];
    },
    expectLeakRecordsCollected,
  );

  leakTest(
    "closed MessagePort removes AbortSignal listener cleanup records",
    () => {
      const controller = new AbortController();
      const channelRefs = [];
      const portRefs = [];
      const listenerRefs = [];

      for (let index = 0; index < 128; index++) {
        let channel = new MessageChannel();
        let listener = () => {};
        channel.port2.addEventListener("message", listener, { signal: controller.signal });
        channel.port2.close();
        channelRefs.push(new WeakRef(channel));
        portRefs.push(new WeakRef(channel.port2));
        listenerRefs.push(new WeakRef(listener));
        listener = null;
        channel = null;
      }

      return {
        signal: controller.signal,
        records: [
          weakRecord("signal-cleared MessageChannel", channelRefs, 8),
          weakRecord("signal-cleared MessagePort", portRefs, 8),
          weakRecord("signal-cleared MessagePort listener", listenerRefs, 8),
        ],
      };
    },
    state => {
      assert.equal(state.signal.aborted, false);
      expectLeakRecordsCollected(state.records);
    },
  );
});
