// A route that reaches lib/lazy_value.js only through import(). The server
// packs the target of the string-literal call at boot, so the worker loads it
// from the route's pack; a computed specifier then loads it too, since the
// pack holds it, while one for a module no pack holds rejects
// (runtime/tests/integration/local_server/e2e.zig).
export default async function handler() {
  const lazy = await import("./lib/lazy_value.js");
  const packed = "./lib/" + "lazy_value.js";
  const again = await import(packed);
  let missing = "";
  try {
    await import("./lib/" + "absent.js");
  } catch (err) {
    missing = err.message;
  }
  return Response.json({ value: lazy.value, same: lazy === again, missing });
}
