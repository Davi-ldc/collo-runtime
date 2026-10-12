// Answers with a token drawn once per worker process. With `?spin=1` it
// first leaves behind JavaScript that no request owns: a FinalizationRegistry
// whose callback never returns, over targets nothing keeps, then enough
// garbage that the engine collects them. The collection schedules the
// registry's cleanup on the engine's deferred work, which the worker runs
// under its own owner once the request is answered, so only the limit the
// definition's `timeoutMs` gives that owner can stop it
// (runtime/tests/integration/local_server/limits.zig). The handler stays
// synchronous, so its response is decided before the cleanup can run.
let token = "";

// Enough targets that a collection finds some of them dead, whatever a
// conservative scan of the stack keeps alive.
const targets = 4096;
// Garbage in 1 MiB buffers, far past what the engine lets a heap allocate
// between two collections, so at least one collection runs.
const garbageMiB = 256;

export default function handler(req) {
  if (token === "") token = crypto.randomUUID();
  if (req.query.get("spin") === "1") {
    globalThis.spinningRegistry = new FinalizationRegistry(() => {
      for (;;) {}
    });
    for (let i = 0; i < targets; i++) globalThis.spinningRegistry.register({ i }, i);
    let garbageBytes = 0;
    for (let mib = 0; mib < garbageMiB; mib++) garbageBytes += new ArrayBuffer(1 << 20).byteLength;
    if (garbageBytes !== garbageMiB << 20) throw new Error("garbage was not allocated");
  }
  return Response.json({ token });
}
