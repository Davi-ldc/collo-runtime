// Answers with a body streamed from a ReadableStream the handler builds
// (runtime/tests/integration/local_server/streams.zig). `?events=N&ms=M`
// sends N server-sent events M milliseconds apart and closes; `?fail=K`
// errors the stream instead of sending event K; `?bytes=N` sends N bytes of
// "a" in 64 KiB chunks, each made only once the worker has sent the one
// before.
// Every response carries `x-worker-token`, drawn once per worker process, so
// two responses with one token came from one worker.
let token = "";

const chunk_bytes = 64 * 1024;

export default function handler(req) {
  if (token === "") token = crypto.randomUUID();
  const total = Number(req.query.get("bytes") ?? "0");
  if (total > 0) return bytesResponse(total);
  return eventsResponse(
    Number(req.query.get("events") ?? "0"),
    Number(req.query.get("ms") ?? "0"),
    req.query.has("fail") ? Number(req.query.get("fail")) : -1,
  );
}

function bytesResponse(total) {
  const chunk = new Uint8Array(chunk_bytes).fill(0x61);
  let sent = 0;
  const body = new ReadableStream(
    {
      pull(controller) {
        if (sent >= total) {
          controller.close();
          return;
        }
        const size = Math.min(chunk.length, total - sent);
        controller.enqueue(chunk.slice(0, size));
        sent += size;
      },
    },
    { highWaterMark: 0 },
  );
  return new Response(body, {
    headers: { "content-type": "application/octet-stream", "x-worker-token": token },
  });
}

function eventsResponse(events, ms, fail) {
  const encoder = new TextEncoder();
  let index = 0;
  const body = new ReadableStream(
    {
      async pull(controller) {
        if (index > 0) await new Promise((resolve) => setTimeout(resolve, ms));
        if (index === fail) {
          controller.error(new Error("stream failed on purpose"));
          return;
        }
        if (index === events) {
          controller.close();
          return;
        }
        controller.enqueue(encoder.encode(`data: ${index}\n\n`));
        index += 1;
      },
    },
    { highWaterMark: 0 },
  );
  return new Response(body, {
    headers: { "content-type": "text/event-stream", "x-worker-token": token },
  });
}
