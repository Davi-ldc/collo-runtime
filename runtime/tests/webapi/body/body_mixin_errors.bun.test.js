import { describe, expect, it } from "collo:test";

describe("body-mixin-errors", () => {
  it.concurrent.each([
    ["Response", () => new Response("a"), (b) => b.text()],
    [
      "Request",
      () => new Request("https://example.com", { body: "{}", method: "POST" }),
      (b) => b.json(),
    ],
  ])("should throw TypeError when body already used on %s", async (type, createBody, secondCall) => {
    const body = createBody();
    await body.text();

    try {
      await secondCall(body);
      expect.unreachable("body is already used");
    } catch (err) {
      expect(err.name).toBe("TypeError");
      expect(err.message).toBe("Body already used");
      expect(err instanceof TypeError).toBe(true);
    }
  });
});
