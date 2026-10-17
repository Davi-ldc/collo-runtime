// The front worker of the workerd side's one process. It owns a workerLoader
// binding and loads tenant t<N> on the first request whose path starts with
// /t<N>/, from the same source Collo's definition t<N> runs (sources.json,
// written by density.js), then hands every request below that prefix to it.
// Each loaded tenant gets its own V8 isolate in this process; the front plays
// the part of Collo's server, so its memory is workerd's base.
import sources from "sources.json";

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/ping") return new Response("ok\n");
    const name = /^\/(t[0-9]+)\//.exec(pathname)?.[1];
    if (name === undefined || !Object.hasOwn(sources.tenants, name)) return new Response("no such tenant\n", { status: 404 });
    const tenant = env.LOADER.get(name, () => ({
      compatibilityDate: sources.compatibilityDate,
      mainModule: "main.js",
      modules: { "main.js": sources.tenants[name] },
    }));
    return tenant.getEntrypoint().fetch(request);
  },
};
