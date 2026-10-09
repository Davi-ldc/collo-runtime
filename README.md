# Collo

Collo is a blazingly fast JavaScript running for serverless envirments. Workers start in ~10ms using ~9 MiB while keeping a strong process isolation boundary and flexibility. 

## Getting started

Write an ES module that accepts a standard `Request` and returns a `Response`, or a promise of one.

`app.js`

```js
export default function handle(request, env = {}) {
  return new Response(env.SECRET ?? "Hello, world!\n");
}
```

Declare a worker, its routes and the server settings in `collo.json`.

```jsonc
{
  "globalSettings": {
    "listen": "127.0.0.1:8080",
    // Structured logs and usage records stay in this directory.
    "analytics": { "directory": "./usage" },
    // Defaults for every worker.
    "isolateRealm": true,  // Each route gets its own realm.
    "limits": {
      "memoryMiB": 64,     // Per worker process, shared by its routes.
      "concurrency": 8,    // In-flight requests per worker process, across its routes.
      "cpuMs": 50,         // CPU time per request.
      "timeoutMs": 1000    // Wall-clock time per request, including I/O waits.
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
curl http://127.0.0.1:8080/
```

For a single local invocation:

```sh
collo run app.js
```

# Why 

Currently, to run serverless JavaScript you can either use generic heavy systems (e.g. gVisor or Firecracker) that use a lot of memory (aka dollars) and take a long time to start, or use Cloudflare Workers, that are cheap and start fast but are incredibly limited and slow due to the lack of isolation (workers are threads in the same process).

Collo's approach sits in between. It uses the same insight as Cloudflare (if you control the runtime, you can work with less isolation, saving a lot of memory). But instead of putting everyone in the same process, Collo optimizes for shared memory: every worker gets its own process, and JSC's GC and allocation strategy touch fewer pages, which maximizes the memory those processes share.[^1]

## How it works

todo

[^1]: 