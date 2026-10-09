export default function handler() {
  // A synchronous spin never yields to the event loop, so only the worker's
  // deadline sentinel, which interrupts the VM from its own thread, ends it.
  for (;;) {}
}
