# Collo

JavaScript will soon be faster than Go and > 50% of all agent written code. Colo is the cheapest, fastest and most flexible way of running it on the server.

Like Cloudflare Workers, Collo aims to reduce JavaScript runtime overhead between tenants. But instead of isolating in the same process (which prevents multi-threading, impacts performance, and compromises security), Collo gives each worker its own process that shares global memory from a zygote. A Collo worker uses 10% less memory (1.95 MiB), and is 10-50% faster than an isolate in Workerd with none of the compromises (no real fs, multithreading, eval/new function, safety[^1])

It's also built on top of Bun's fork of Webkit/JavaScriptCore to support future [aot compilation](https://github.com/oven-sh/WebKit/pull/757), [multithreading](https://github.com/oven-sh/WebKit/pull/249), and [jitcache](https://github.com/Davi-ldc/jitcache) 

[bench](bench.md)

## Getting started

Write an ES module whose default export has a `fetch(request, env)`. It receives a standard `Request` and returns a `Response`, or a promise of one. A default export that is itself such a function works too :)

```js
export default {
  fetch(request, env) {
    return new Response(env.SECRET ?? "Hello, world!\n");
  },
};
```

Declare a worker, its routes and the server settings in `collo.json`.

```jsonc
{
  "settings": {
    "listen": "127.0.0.1:8080",
    // Structured logs and usage records stay in this directory.
    "analytics": { "directory": "./usage" },
    // Outbound fetch reaches only these hosts; without "network" it reaches none.
    "network": { "allow": ["api.example.com", "*.example.org"] },
    // Defaults for every worker.
    "isolateRealm": true,  // A realm is basicly the globalthis + Global Scope and builtins
    "limits": {
      "memoryMiB": 64,     // Per worker process, shared by its routes.
      "concurrency": 8,    // In-flight requests per worker process, across its routes (default 2, at most 16).
      "cpuMs": 50,         // CPU time per request; past it the request gets 503. No default.
      "timeoutMs": 1000    // Wall-clock time per request
    }
  },
  "workers": {
    "site": {
      // Each route is an entrypoint with its own bindings.
      "routes": {
        "/": {
          "entry": "./app.js",
          "bindings": { "SECRET": { "text": "Hello from Collo!\n" } }
        },
        "/status": {
          "entry": "./app.js",
          "bindings": { "SECRET": { "text": "OK\n" } }
        }
      },
      // Overrides the defaults for this worker only.
      "settings": {
        "limits": { "memoryMiB": 128 }
      }
    }
  }
}
```

```sh
collo serve collo.json
curl -k https://127.0.0.1:8080/   # HTTPS and HTTP/2 only; self-signed unless settings.tls names a certificate
```

To serve one module on every path without a `collo.json` (its `fetch` may reach any public host):

```sh
collo serve app.js
```

## Why 

With [sound types, aot compilation](https://github.com/oven-sh/WebKit/pull/757), [multithreading](https://github.com/oven-sh/WebKit/pull/249), and [jitcache](https://github.com/Davi-ldc/jitcache) JS will soon be faster them go and > 50% of all agent writen code. 

One of the coolest part about it is that, because you control the runtime, [JS is (technically) extremely cheap to run](https://developers.cloudflare.com/workers/platform/pricing/). Sadly, current options today are either generic heavy systems (like gVisor or Firecracker) that use a lot of memory (aka dollars) and take a long time to start, or Cloudflare Workers, that are cheap and start fast but are incredibly limited and algorithmically slow. Also, because of the current architecture on top of v8, workers wont support AOT, jitcache or multithreading.

Collo solves that. 

## How it works

![How Collo works](assets/collo.gif)

TODO.

## Footnotes

[^1]: Unlike Collo, workerd is not a hardened sandbox by itself. CloudFlare [uses many additional layers of defense-in-depth.](https://blog.cloudflare.com/mitigating-spectre-and-other-security-threats-the-cloudflare-workers-security-model/)