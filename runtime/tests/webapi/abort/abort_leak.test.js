// Leak coverage derived from Bun v1.3.14 intent:
// - reference/bun-v1.3.14/test/js/web/abort/abort-signal-event-listener-leak.test.ts
// - reference/bun-v1.3.14/test/js/web/fetch/abort-signal-leak.test.ts

describeLeaks("AbortSignal retention", () => {
  leakTest(
    "discarded AbortSignal.any dependents are not retained by a live source signal",
    () => {
      const controller = new AbortController();
      const refs = [];

      for (let index = 0; index < 512; index++) {
        let signal = AbortSignal.any([controller.signal]);
        refs.push(new WeakRef(signal));
        signal = null;
      }

      return {
        controller,
        records: [
          weakRecord("discarded AbortSignal.any dependent", refs, 16),
        ],
      };
    },
    ({ records }) => expectLeakRecordsCollected(records),
  );

  leakTest(
    "removeEventListener releases listener signal cleanup records",
    () => {
      const controller = new AbortController();
      const targetRefs = [];
      const listenerRefs = [];

      for (let index = 0; index < 512; index++) {
        let target = new EventTarget();
        let listener = () => {};
        target.addEventListener("tick", listener, { signal: controller.signal });
        target.removeEventListener("tick", listener);
        targetRefs.push(new WeakRef(target));
        listenerRefs.push(new WeakRef(listener));
        target = null;
        listener = null;
      }

      return {
        controller,
        records: [
          weakRecord("removed signal listener target", targetRefs, 16),
          weakRecord("removed signal listener callback", listenerRefs, 16),
        ],
      };
    },
    ({ records }) => expectLeakRecordsCollected(records),
  );

  leakTest(
    "once listeners registered with signal are released after dispatch",
    () => {
      const controller = new AbortController();
      const targetRefs = [];
      const listenerRefs = [];

      for (let index = 0; index < 512; index++) {
        let target = new EventTarget();
        let listener = () => {};
        target.addEventListener("tick", listener, { signal: controller.signal, once: true });
        target.dispatchEvent(new Event("tick"));
        targetRefs.push(new WeakRef(target));
        listenerRefs.push(new WeakRef(listener));
        target = null;
        listener = null;
      }

      return {
        controller,
        records: [
          weakRecord("once signal listener target", targetRefs, 16),
          weakRecord("once signal listener callback", listenerRefs, 16),
        ],
      };
    },
    ({ records }) => expectLeakRecordsCollected(records),
  );

  leakTest(
    "self-referencing signal option listeners are collectable",
    () => {
      const signalRefs = [];
      const listenerRefs = [];

      for (let index = 0; index < 512; index++) {
        let controller = new AbortController();
        let listener = () => {};
        controller.signal.addEventListener("abort", listener, { signal: controller.signal });
        signalRefs.push(new WeakRef(controller.signal));
        listenerRefs.push(new WeakRef(listener));
        controller = null;
        listener = null;
      }

      return [
        weakRecord("self-referencing AbortSignal", signalRefs, 16),
        weakRecord("self-referencing AbortSignal listener", listenerRefs, 16),
      ];
    },
    expectLeakRecordsCollected,
  );
});
