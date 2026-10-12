// Spins synchronously and never yields to the event loop, so only the
// worker's sentinel ends the request: from its own thread it interrupts the
// VM once the request passes its wall deadline or has spent its `cpuMs`
// (runtime/tests/integration/local_server/e2e.zig and limits.zig).
export default function handler() {
  for (;;) {}
}
