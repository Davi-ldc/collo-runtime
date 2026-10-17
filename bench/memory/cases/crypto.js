// Checks a webhook's HMAC-SHA256 signature: the hex digest of the body under
// the shared secret must equal the x-signature header.
let key;

export default {
  async fetch(request) {
    // workerd refuses crypto work at global scope, so the key is imported on
    // the first request and kept for the rest.
    key ??= await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode("whsec_example"),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const digest = await crypto.subtle.sign("HMAC", key, await request.arrayBuffer());
    const signature = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
    return Response.json({ valid: signature === request.headers.get("x-signature") });
  },
};
