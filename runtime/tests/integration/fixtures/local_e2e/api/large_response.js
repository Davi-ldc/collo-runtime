const body = "x".repeat(4 * 1024 * 1024);

export default function handler() {
  return new Response(body, {
    headers: {
      "content-type": "text/plain"
    }
  });
}
