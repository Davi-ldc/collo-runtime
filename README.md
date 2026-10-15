# Collo

Collo is fast and flexible JavaScript runtime for isolating workers in serverless envirments. 

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

## Memory

What one more worker costs once 16 run, M(17) − M(16), in MiB, after each worker served the same requests and went idle. Every worker runs its own copy of the module, as separate tenants would. Median of 5 runs on an Oracle Cloud A1 (Ampere Altra, aarch64), Collo at `4472501` against workerd 1.20261012.1.

| Workload | Collo | workerd | workerd, one process per worker |
| --- | ---: | ---: | ---: |
| hello | 2.11 | 2.25 | 8.32 |
| Hono API | 4.32 | 2.74 | 9.54 |
| crypto | 4.04 | 11.94 | 20.47 |

These are the cgroup's `memory.current`, everything the machine pays, kernel memory included. A Collo worker is a process with its own page tables, kernel stacks and slab, about 0.8 MiB that an isolate inside a shared process does not pay. Counting only the processes' own memory (PSS), a Collo worker costs 1.41, 3.70 and 3.37 MiB against workerd's 2.07, 2.73 and 11.97.

workerd runs every worker as an isolate in one shared process, which its README says needs an outer sandbox for untrusted code; the last column gives workerd the process boundary every Collo worker has. Hono API is an unmodified Hono app with a router, an API-key middleware and a JSON validator, measured after ten requests across its routes. crypto, a 4 MiB SHA-256 in JavaScript and four 2048-bit BigInt modular exponentiations, shows what each runtime keeps after a burst of allocation: Collo collects when a worker goes idle, and workerd keeps the grown heap.

# Why 

With [sound types, aot compilation](https://github.com/oven-sh/WebKit/pull/757), [multithreading](https://github.com/oven-sh/WebKit/pull/249), and [jitcache](https://github.com/Davi-ldc/jitcache) JS will soon be faster them go and > 50% of all agent writen code. 

One of the coolest part about it is that, because you control the runtime, [JS is (technically) extremely cheap to run](https://developers.cloudflare.com/workers/platform/pricing/). Sadly, current options today are either generic heavy systems (like gVisor or Firecracker) that use a lot of memory (aka dollars) and take a long time to start, or Cloudflare Workers, that are cheap and start fast but are incredibly limited and algorithmically slow. Also, because of the current architecture on top of v8, workers wont support AOT, jitcache or multithreading.

Collo solves that. 

## How it works

The core idea is to isolate workers between processes that come from a Linux fork and let them share as much memory as possible (JSC allocations favor this). 
