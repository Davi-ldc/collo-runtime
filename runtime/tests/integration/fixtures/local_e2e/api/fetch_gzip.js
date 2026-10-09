export default async function handler(req) {
  const host = req.query.get("host");
  const port = req.query.get("port");
  const target = "http://" + host + ":" + port + "/gzip";

  const res = await fetch(target);
  const text = await res.text();

  const streamedRes = await fetch(target);
  const reader = streamedRes.body.getReader();
  const decoder = new TextDecoder();
  let streamed = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    streamed += decoder.decode(value, { stream: true });
  }
  streamed += decoder.decode();

  return Response.json({
    status: res.status,
    encoding: res.headers.get("content-encoding") || "",
    text,
    streamed
  });
}
