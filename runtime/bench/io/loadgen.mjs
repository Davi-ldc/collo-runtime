// Closed-loop HTTPS load generator for the I/O comparison in README.md.
//
// The parent forks child processes, splits the connections between them
// round robin, and waits until every connection has finished its TLS
// handshake (and, for HTTP/2, received the server's SETTINGS). Each child then
// keeps a fixed number of requests in flight on every connection: a new
// request leaves as soon as one completes. A warm-up runs first and is not
// recorded; the measured window follows. Latency runs from queueing a request
// on the socket to receiving the end of its response, and lands in a
// histogram with 1 µs buckets below 100 ms and 100 µs buckets above.
//
// HTTP/2 is spoken directly on the TLS socket: a constant HPACK header block
// per request, no dynamic table on the client side, and only the frames a GET
// with a short response needs. Responses count as successful only with status
// 200 and a body equal to --expect. HTTP/1.1 keeps one request in flight per
// connection, without pipelining.
//
// Usage: node loadgen.mjs --url https://127.0.0.1:8443/ --proto h2|h1
//   --connections N [--streams M] [--procs P] [--warmup-s S] [--duration-s S]
//   [--ca cert.pem] [--expect 'hello\n'] [--cgroup DIR] [--label NAME]
//   [--log-file FILE --log-pattern TEXT] [--out results.json]
// --cgroup names the server's cgroup. Its cpu.stat gives the server's CPU use
// over the measured window, split into user and system time; memory.current
// gives its memory at the end of the window; the `worker-*` directories two
// levels under its `workers` branch count the Collo workers alive.
// /proc/stat gives the whole machine's CPU use. --log-file and --log-pattern
// count the lines of the server's log that contain the pattern and appear
// during the window.

import { fork } from "node:child_process";
import fs from "node:fs";
import tls from "node:tls";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const linearBucketsUs = 100_000;
const coarseStepUs = 100;
const coarseBuckets = 600_000;
const histogramSize = linearBucketsUs + coarseBuckets;
const drainTimeoutMs = 5_000;

function bucketOf(us) {
  if (us < linearBucketsUs) return us;
  return Math.min(histogramSize - 1, linearBucketsUs + Math.floor((us - linearBucketsUs) / coarseStepUs));
}

function valueOf(bucket) {
  if (bucket < linearBucketsUs) return bucket;
  return linearBucketsUs + (bucket - linearBucketsUs) * coarseStepUs + coarseStepUs / 2;
}

function parseArgs(argv) {
  const args = {
    proto: "h2", connections: 1, streams: 1, procs: 8, warmupS: 5, durationS: 10,
    expect: "hello\n", label: "", out: "", ca: "", cgroup: "", url: "", logFile: "", logPattern: "",
  };
  const keys = {
    "--url": "url", "--proto": "proto", "--connections": "connections", "--streams": "streams",
    "--procs": "procs", "--warmup-s": "warmupS", "--duration-s": "durationS", "--expect": "expect",
    "--label": "label", "--out": "out", "--ca": "ca", "--cgroup": "cgroup",
    "--log-file": "logFile", "--log-pattern": "logPattern",
  };
  for (let i = 0; i < argv.length; i += 2) {
    const key = keys[argv[i]];
    if (!key || i + 1 >= argv.length) throw new Error(`bad argument ${argv[i]}`);
    const raw = argv[i + 1];
    args[key] = typeof args[key] === "number" ? Number(raw) : raw;
  }
  args.expect = args.expect.replace(/\\n/g, "\n");
  if (!args.url) throw new Error("--url is required");
  if (args.proto !== "h2" && args.proto !== "h1") throw new Error("--proto is h2 or h1");
  if (args.proto === "h1" && args.streams !== 1) throw new Error("HTTP/1.1 keeps one request in flight per connection");
  return args;
}

// ---------------------------------------------------------------- child side

class Recorder {
  constructor() {
    this.histogram = new Uint32Array(histogramSize);
    this.count = 0;
    this.errors = { rst: 0, goaway: 0, status: 0, body: 0, connection: 0, unknownStatus: 0 };
    this.recordFrom = Infinity;
    this.recordUntil = Infinity;
    this.statusSample = null;
  }
  inWindow(now) {
    return now >= this.recordFrom && now < this.recordUntil;
  }
  complete(start, now) {
    if (!this.inWindow(now)) return;
    this.count += 1;
    this.histogram[bucketOf(Math.round((now - start) * 1000))] += 1;
  }
  error(kind, now) {
    if (now === undefined || this.inWindow(now)) this.errors[kind] += 1;
  }
}

const h2Preface = Buffer.from("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", "latin1");
const frameType = { data: 0, headers: 1, priority: 2, rst: 3, settings: 4, push: 5, ping: 6, goaway: 7, window: 8, continuation: 9 };
const flag = { endStream: 0x1, ack: 0x1, endHeaders: 0x4, padded: 0x8, priority: 0x20 };
const clientConnectionWindow = 1 << 30;
const clientStreamWindow = 1 << 20;

function frame(type, flags, streamId, payload) {
  const out = Buffer.allocUnsafe(9 + payload.length);
  out.writeUIntBE(payload.length, 0, 3);
  out[3] = type;
  out[4] = flags;
  out.writeUInt32BE(streamId, 5);
  payload.copy(out, 9);
  return out;
}

function hpackString(value) {
  const bytes = Buffer.from(value, "latin1");
  if (bytes.length >= 127) throw new Error("header value too long for a one-byte length");
  return Buffer.concat([Buffer.from([bytes.length]), bytes]);
}

// :status values a static-table index can carry (RFC 7541, appendix A).
const staticStatus = { 8: 200, 9: 204, 10: 206, 11: 304, 12: 400, 13: 404, 14: 500 };

// The status of a response header block. :status comes first, and every
// encoder seen here sends 200 as the indexed static entry 0x88; literal forms
// with a static name are decoded too, the rest count as unknown.
function statusOf(block) {
  if (block.length === 0) return -1;
  const first = block[0];
  if (first & 0x80) return staticStatus[first & 0x7f] ?? -1;
  let index;
  if ((first & 0xc0) === 0x40) index = first & 0x3f;
  else if ((first & 0xf0) === 0x00 || (first & 0xf0) === 0x10) index = first & 0x0f;
  else return -1;
  if (index < 8 || index > 14 || block.length < 2) return -1;
  const huffman = (block[1] & 0x80) !== 0;
  const length = block[1] & 0x7f;
  if (block.length < 2 + length) return -1;
  const value = block.subarray(2, 2 + length);
  if (!huffman) return Number(value.toString("latin1"));
  if (length === 2 && value[0] === 0x10 && value[1] === 0x01) return 200;
  return -1;
}

class H2Connection {
  constructor(options, recorder, onReady) {
    this.options = options;
    this.recorder = recorder;
    this.onReady = onReady;
    this.nextStreamId = 1;
    this.streams = new Map();
    this.pending = null;
    this.consumed = 0;
    this.serverSettingsSeen = false;
    this.serverMaxStreams = Infinity;
    this.stopping = false;
    this.dead = false;
    this.continuationStream = 0;
    const authority = `${options.host}:${options.port}`;
    const block = Buffer.concat([
      Buffer.from([0x82, 0x87, 0x84]), // :method GET, :scheme https, :path /
      Buffer.from([0x01]), hpackString(authority), // :authority, literal without indexing
    ]);
    this.requestTemplate = frame(frameType.headers, flag.endStream | flag.endHeaders, 0, block);
    this.expect = Buffer.from(options.expect, "latin1");
    this.socket = tls.connect({
      host: options.host, port: options.port, ALPNProtocols: ["h2"], ca: options.ca,
      rejectUnauthorized: options.ca !== undefined, servername: options.servername,
    });
    this.socket.setNoDelay(true);
    this.socket.on("secureConnect", () => {
      if (this.socket.alpnProtocol !== "h2") {
        this.fail(`server negotiated ${this.socket.alpnProtocol || "no protocol"}, not h2`);
        return;
      }
      const settings = Buffer.alloc(12);
      settings.writeUInt16BE(0x2, 0); settings.writeUInt32BE(0, 2); // ENABLE_PUSH
      settings.writeUInt16BE(0x4, 6); settings.writeUInt32BE(clientStreamWindow, 8); // INITIAL_WINDOW_SIZE
      const windowUpdate = Buffer.alloc(4);
      windowUpdate.writeUInt32BE(clientConnectionWindow - 65535, 0);
      this.socket.write(Buffer.concat([h2Preface, frame(frameType.settings, 0, 0, settings), frame(frameType.window, 0, 0, windowUpdate)]));
    });
    this.socket.on("data", (chunk) => this.onData(chunk));
    this.socket.on("error", (error) => this.fail(error.message));
    this.socket.on("close", () => {
      if (!this.dead && !this.stopping) this.fail("connection closed");
      this.dead = true;
    });
  }

  meta() {
    const cert = this.socket.getPeerCertificate();
    return {
      alpn: this.socket.alpnProtocol, tlsVersion: this.socket.getProtocol(),
      cipher: this.socket.getCipher()?.standardName, certSha256: cert?.fingerprint256,
      serverMaxConcurrentStreams: Number.isFinite(this.serverMaxStreams) ? this.serverMaxStreams : null,
    };
  }

  fail(message) {
    if (this.dead) return;
    this.dead = true;
    this.recorder.error("connection", performance.now());
    if (!this.recorder.firstFailure) this.recorder.firstFailure = message;
    this.socket.destroy();
    this.onReady?.(new Error(message));
    this.onReady = null;
  }

  start(count) {
    if (count > this.serverMaxStreams) {
      this.fail(`server allows ${this.serverMaxStreams} concurrent streams, asked for ${count}`);
      return;
    }
    const out = [];
    for (let i = 0; i < count; i += 1) out.push(this.request());
    this.socket.write(out.length === 1 ? out[0] : Buffer.concat(out));
  }

  request() {
    const id = this.nextStreamId;
    this.nextStreamId += 2;
    const bytes = Buffer.from(this.requestTemplate);
    bytes.writeUInt32BE(id, 5);
    this.streams.set(id, { start: performance.now(), length: 0, bad: false, status: 0 });
    return bytes;
  }

  finish(id, out) {
    const stream = this.streams.get(id);
    if (!stream) return;
    this.streams.delete(id);
    const now = performance.now();
    if (stream.status === -1) this.recorder.error("unknownStatus", now);
    else if (stream.status !== 200) this.recorder.error("status", now);
    else if (stream.bad || stream.length !== this.expect.length) this.recorder.error("body", now);
    else this.recorder.complete(stream.start, now);
    if (!this.stopping && now < this.recorder.recordUntil) out.push(this.request());
    else if (this.streams.size === 0) this.recorder.connectionDrained(this);
  }

  onData(chunk) {
    let buffer = this.pending ? Buffer.concat([this.pending, chunk]) : chunk;
    this.pending = null;
    const out = [];
    let offset = 0;
    while (buffer.length - offset >= 9) {
      const length = buffer.readUIntBE(offset, 3);
      if (buffer.length - offset < 9 + length) break;
      const type = buffer[offset + 3];
      const flags = buffer[offset + 4];
      const id = buffer.readUInt32BE(offset + 5) & 0x7fffffff;
      const payload = buffer.subarray(offset + 9, offset + 9 + length);
      offset += 9 + length;
      this.onFrame(type, flags, id, payload, out);
      if (this.dead) return;
    }
    if (offset < buffer.length) this.pending = buffer.subarray(offset);
    if (this.consumed >= clientConnectionWindow / 2) {
      const increment = Buffer.alloc(4);
      increment.writeUInt32BE(this.consumed, 0);
      out.push(frame(frameType.window, 0, 0, increment));
      this.consumed = 0;
    }
    if (out.length > 0) this.socket.write(out.length === 1 ? out[0] : Buffer.concat(out));
  }

  onFrame(type, flags, id, payload, out) {
    switch (type) {
      case frameType.data: {
        this.consumed += payload.length;
        const stream = this.streams.get(id);
        if (stream) {
          const pad = flags & flag.padded ? payload[0] : 0;
          const data = payload.subarray(flags & flag.padded ? 1 : 0, payload.length - pad);
          if (stream.length + data.length > this.expect.length ||
              !data.equals(this.expect.subarray(stream.length, stream.length + data.length))) stream.bad = true;
          stream.length += data.length;
        }
        if (flags & flag.endStream) this.finish(id, out);
        break;
      }
      case frameType.headers: {
        const stream = this.streams.get(id);
        let start = 0;
        let pad = 0;
        if (flags & flag.padded) { pad = payload[0]; start = 1; }
        if (flags & flag.priority) start += 5;
        if (stream && stream.status === 0) {
          stream.status = statusOf(payload.subarray(start, payload.length - pad));
          if (stream.status === -1 && !this.recorder.statusSample)
            this.recorder.statusSample = payload.subarray(start, Math.min(payload.length, start + 16)).toString("hex");
        }
        if (!(flags & flag.endHeaders)) {
          this.continuationStream = id;
          this.continuationEnds = (flags & flag.endStream) !== 0;
        } else if (flags & flag.endStream) {
          this.finish(id, out);
        }
        break;
      }
      case frameType.continuation:
        if ((flags & flag.endHeaders) && id === this.continuationStream) {
          this.continuationStream = 0;
          if (this.continuationEnds) this.finish(id, out);
        }
        break;
      case frameType.rst: {
        const now = performance.now();
        this.recorder.error("rst", now);
        if (!this.recorder.firstFailure) this.recorder.firstFailure = `RST_STREAM code ${payload.readUInt32BE(0)}`;
        const stream = this.streams.get(id);
        if (stream) {
          this.streams.delete(id);
          if (!this.stopping && now < this.recorder.recordUntil) out.push(this.request());
          else if (this.streams.size === 0) this.recorder.connectionDrained(this);
        }
        break;
      }
      case frameType.settings:
        if (flags & flag.ack) break;
        for (let i = 0; i + 6 <= payload.length; i += 6) {
          if (payload.readUInt16BE(i) === 0x3) this.serverMaxStreams = payload.readUInt32BE(i + 2);
        }
        out.push(frame(frameType.settings, flag.ack, 0, Buffer.alloc(0)));
        if (!this.serverSettingsSeen) {
          this.serverSettingsSeen = true;
          setImmediate(() => { this.onReady?.(null); this.onReady = null; });
        }
        break;
      case frameType.ping:
        if (!(flags & flag.ack)) out.push(frame(frameType.ping, flag.ack, 0, payload));
        break;
      case frameType.goaway:
        this.recorder.error("goaway", performance.now());
        this.fail(`GOAWAY code ${payload.readUInt32BE(4)}`);
        break;
      case frameType.push:
        this.fail("server sent PUSH_PROMISE although push is disabled");
        break;
      default:
        break;
    }
  }
}

class H1Connection {
  constructor(options, recorder, onReady) {
    this.options = options;
    this.recorder = recorder;
    this.onReady = onReady;
    this.pending = null;
    this.start = 0;
    this.inFlight = false;
    this.stopping = false;
    this.dead = false;
    this.requestBytes = Buffer.from(`GET / HTTP/1.1\r\nHost: ${options.host}:${options.port}\r\n\r\n`, "latin1");
    this.expect = Buffer.from(options.expect, "latin1");
    this.socket = tls.connect({
      host: options.host, port: options.port, ALPNProtocols: ["http/1.1"], ca: options.ca,
      rejectUnauthorized: options.ca !== undefined, servername: options.servername,
    });
    this.socket.setNoDelay(true);
    this.socket.on("secureConnect", () => { this.onReady?.(null); this.onReady = null; });
    this.socket.on("data", (chunk) => this.onData(chunk));
    this.socket.on("error", (error) => this.fail(error.message));
    this.socket.on("close", () => {
      if (!this.dead && !this.stopping) this.fail("connection closed");
      this.dead = true;
    });
  }

  meta() {
    const cert = this.socket.getPeerCertificate();
    return {
      alpn: this.socket.alpnProtocol || "none (HTTP/1.1)", tlsVersion: this.socket.getProtocol(),
      cipher: this.socket.getCipher()?.standardName, certSha256: cert?.fingerprint256,
      serverMaxConcurrentStreams: null,
    };
  }

  fail(message) {
    if (this.dead) return;
    this.dead = true;
    this.recorder.error("connection", performance.now());
    if (!this.recorder.firstFailure) this.recorder.firstFailure = message;
    this.socket.destroy();
    this.onReady?.(new Error(message));
    this.onReady = null;
  }

  begin() {
    this.start = performance.now();
    this.inFlight = true;
    this.socket.write(this.requestBytes);
  }

  // One response from `buffer`, or null when it is not complete yet.
  parse(buffer) {
    const headEnd = buffer.indexOf("\r\n\r\n", 0, "latin1");
    if (headEnd === -1) return null;
    const head = buffer.toString("latin1", 0, headEnd);
    const status = Number(head.slice(9, 12));
    const lengthMatch = /\r\ncontent-length:[ \t]*(\d+)/i.exec(head);
    if (lengthMatch) {
      const length = Number(lengthMatch[1]);
      const end = headEnd + 4 + length;
      if (buffer.length < end) return null;
      return { status, body: buffer.subarray(headEnd + 4, end), end };
    }
    if (!/\r\ntransfer-encoding:[ \t]*chunked/i.test(head)) throw new Error("response has neither content-length nor chunked encoding");
    const parts = [];
    let cursor = headEnd + 4;
    for (;;) {
      const lineEnd = buffer.indexOf("\r\n", cursor, "latin1");
      if (lineEnd === -1) return null;
      const size = parseInt(buffer.toString("latin1", cursor, lineEnd), 16);
      cursor = lineEnd + 2;
      if (buffer.length < cursor + size + 2) return null;
      if (size === 0) return { status, body: Buffer.concat(parts), end: cursor + 2 };
      parts.push(buffer.subarray(cursor, cursor + size));
      cursor += size + 2;
    }
  }

  onData(chunk) {
    let buffer = this.pending ? Buffer.concat([this.pending, chunk]) : chunk;
    this.pending = null;
    let response;
    try {
      response = this.parse(buffer);
    } catch (error) {
      this.fail(error.message);
      return;
    }
    if (!response) { this.pending = buffer; return; }
    if (response.end < buffer.length) { this.fail("bytes after the response although no request was pipelined"); return; }
    this.inFlight = false;
    const now = performance.now();
    if (response.status !== 200) this.recorder.error("status", now);
    else if (!response.body.equals(this.expect)) this.recorder.error("body", now);
    else this.recorder.complete(this.start, now);
    if (!this.stopping && now < this.recorder.recordUntil) this.begin();
    else this.recorder.connectionDrained(this);
  }
}

function runChild() {
  let connections = [];
  const recorder = new Recorder();
  let drained = 0;
  let cpuAtStart = null;
  let cpuUs = 0;
  let finished = false;
  let windowClosed = false;

  const report = (reason) => {
    if (finished) return;
    finished = true;
    const sparse = [];
    for (let i = 0; i < recorder.histogram.length; i += 1) if (recorder.histogram[i] !== 0) sparse.push(i, recorder.histogram[i]);
    process.send({
      kind: "result", reason, count: recorder.count, errors: recorder.errors, histogram: sparse, cpuUs,
      firstFailure: recorder.firstFailure ?? null, statusSample: recorder.statusSample,
    }, () => process.exit(0));
  };

  // A connection can go idle past the window before the end timer runs, so
  // the result waits for both: the timer records the CPU use, and each
  // connection counts once.
  recorder.connectionDrained = (connection) => {
    if (connection.drainCounted) return;
    connection.drainCounted = true;
    drained += 1;
    if (windowClosed && drained >= connections.length) report("drained");
  };

  process.on("message", (message) => {
    if (message.kind === "connect") {
      const options = { ...message.options, ca: message.options.ca ? Buffer.from(message.options.ca, "latin1") : undefined };
      let ready = 0;
      let failed = false;
      const Connection = options.proto === "h2" ? H2Connection : H1Connection;
      connections = Array.from({ length: message.connections }, () => new Connection(options, recorder, (error) => {
        if (failed) return;
        if (error) { failed = true; process.send({ kind: "failed", message: error.message }); return; }
        ready += 1;
        if (ready === connections.length) process.send({ kind: "ready", meta: connections[0].meta() });
      }));
    } else if (message.kind === "go") {
      const now = performance.now();
      recorder.recordFrom = now + message.warmupMs;
      recorder.recordUntil = recorder.recordFrom + message.durationMs;
      setTimeout(() => { cpuAtStart = process.cpuUsage(); }, message.warmupMs);
      setTimeout(() => {
        const used = process.cpuUsage(cpuAtStart);
        cpuUs = used.user + used.system;
        windowClosed = true;
        for (const connection of connections) {
          connection.stopping = true;
          const idle = connection.dead || (connection instanceof H2Connection ? connection.streams.size === 0 : !connection.inFlight);
          if (idle) recorder.connectionDrained(connection);
        }
        if (drained >= connections.length) report("drained");
        setTimeout(() => report("drain timeout"), drainTimeoutMs);
      }, message.warmupMs + message.durationMs);
      for (const connection of connections) {
        if (connection instanceof H2Connection) connection.start(message.streams);
        else connection.begin();
      }
    }
  });
}

// --------------------------------------------------------------- parent side

function readCgroupUsageUs(dir) {
  const text = fs.readFileSync(`${dir}/cpu.stat`, "utf8");
  const field = (name) => Number(new RegExp(`^${name} (\\d+)$`, "m").exec(text)[1]);
  return { usage: field("usage_usec"), user: field("user_usec"), system: field("system_usec") };
}

function readCgroupMemoryBytes(dir) {
  return Number(fs.readFileSync(`${dir}/memory.current`, "utf8").trim());
}

// Collo places each worker in `<scope>/workers/<host root>/worker-<n>`.
function countColloWorkers(dir) {
  let count = 0;
  let roots;
  try {
    roots = fs.readdirSync(`${dir}/workers`, { withFileTypes: true }).filter((entry) => entry.isDirectory());
  } catch {
    return null;
  }
  for (const root of roots) {
    try {
      count += fs.readdirSync(`${dir}/workers/${root.name}`).filter((name) => name.startsWith("worker-")).length;
    } catch {
      // The host root went away with its last worker.
    }
  }
  return count;
}

function countLogLines(file, pattern) {
  let count = 0;
  for (const line of fs.readFileSync(file, "utf8").split("\n")) if (line.includes(pattern)) count += 1;
  return count;
}

// Busy and total jiffies summed over every CPU, from the first line of
// /proc/stat (user nice system idle iowait irq softirq steal ...).
function readProcStat() {
  const fields = fs.readFileSync("/proc/stat", "utf8").split("\n")[0].trim().split(/\s+/).slice(1).map(Number);
  const idle = fields[3] + fields[4];
  const total = fields.slice(0, 8).reduce((a, b) => a + b, 0);
  return { busy: total - idle, total };
}

function percentile(histogram, total, p) {
  const rank = Math.max(1, Math.ceil((p / 100) * total));
  let seen = 0;
  for (let i = 0; i < histogram.length; i += 1) {
    seen += histogram[i];
    if (seen >= rank) return valueOf(i);
  }
  return valueOf(histogram.length - 1);
}

async function runParent(args) {
  const url = new URL(args.url);
  const procs = Math.max(1, Math.min(args.procs, args.connections));
  const perChild = Array.from({ length: procs }, (_, i) => Math.floor(args.connections / procs) + (i < args.connections % procs ? 1 : 0));
  const options = {
    proto: args.proto, host: url.hostname, port: Number(url.port || 443), expect: args.expect,
    ca: args.ca ? fs.readFileSync(args.ca, "latin1") : null, servername: "localhost",
  };
  const self = fileURLToPath(import.meta.url);
  const children = perChild.map(() => fork(self, ["--child"], { stdio: ["ignore", "inherit", "inherit", "ipc"] }));
  const waitFor = (child, kind) => new Promise((resolve, reject) => {
    const onMessage = (message) => {
      if (message.kind === kind) { child.off("message", onMessage); resolve(message); }
      else if (message.kind === "failed") { child.off("message", onMessage); reject(new Error(message.message)); }
    };
    child.on("message", onMessage);
    child.on("exit", (code) => reject(new Error(`load generator child exited with ${code}`)));
  });

  const readies = children.map((child, i) => {
    const promise = waitFor(child, "ready");
    child.send({ kind: "connect", connections: perChild[i], options });
    return promise;
  });
  let meta;
  try {
    meta = (await Promise.all(readies))[0].meta;
  } catch (error) {
    for (const child of children) child.kill();
    throw error;
  }

  const warmupMs = args.warmupS * 1000;
  const durationMs = args.durationS * 1000;
  const results = children.map((child) => waitFor(child, "result"));
  for (const child of children) child.send({ kind: "go", warmupMs, durationMs, streams: args.streams });

  let machineStart = null;
  let serverStart = null;
  let machine = null;
  let serverUs = null;
  let logStart = null;
  const server = {
    userCores: null, systemCores: null, memoryBytesAtEnd: null,
    colloWorkersAtStart: null, colloWorkersAtEnd: null, logMatchesInWindow: null,
  };
  const loadavg = fs.readFileSync("/proc/loadavg", "utf8").trim();
  setTimeout(() => {
    machineStart = readProcStat();
    if (args.cgroup) {
      serverStart = readCgroupUsageUs(args.cgroup);
      server.colloWorkersAtStart = countColloWorkers(args.cgroup);
    }
    if (args.logFile) logStart = countLogLines(args.logFile, args.logPattern);
  }, warmupMs);
  // A child with one connection drains within a millisecond of its window, so
  // its result can arrive before this timer fires; the output waits for both.
  const windowSampled = new Promise((resolve) => setTimeout(() => {
    const end = readProcStat();
    machine = { busy: end.busy - machineStart.busy, total: end.total - machineStart.total };
    if (args.cgroup) {
      const serverEnd = readCgroupUsageUs(args.cgroup);
      serverUs = serverEnd.usage - serverStart.usage;
      server.userCores = (serverEnd.user - serverStart.user) / (durationMs * 1000);
      server.systemCores = (serverEnd.system - serverStart.system) / (durationMs * 1000);
      server.memoryBytesAtEnd = readCgroupMemoryBytes(args.cgroup);
      server.colloWorkersAtEnd = countColloWorkers(args.cgroup);
    }
    if (args.logFile) server.logMatchesInWindow = countLogLines(args.logFile, args.logPattern) - logStart;
    resolve();
  }, warmupMs + durationMs));

  const childResults = await Promise.all(results);
  await windowSampled;
  const histogram = new Float64Array(histogramSize);
  let count = 0;
  let sumUs = 0;
  let maxBucket = 0;
  const errors = { rst: 0, goaway: 0, status: 0, body: 0, connection: 0, unknownStatus: 0 };
  for (const result of childResults) {
    count += result.count;
    for (const key of Object.keys(errors)) errors[key] += result.errors[key];
    for (let i = 0; i < result.histogram.length; i += 2) {
      const bucket = result.histogram[i];
      histogram[bucket] += result.histogram[i + 1];
      sumUs += valueOf(bucket) * result.histogram[i + 1];
      maxBucket = Math.max(maxBucket, bucket);
    }
  }
  const windowS = durationMs / 1000;
  const clientCores = childResults.map((result) => result.cpuUs / (durationMs * 1000));
  const cpus = fs.readFileSync("/proc/cpuinfo", "utf8").split("\n").filter((line) => line.startsWith("processor")).length;
  const machineBusyCores = machine ? (machine.busy / machine.total) * cpus : null;
  const serverCores = serverUs === null ? null : serverUs / (durationMs * 1000);
  const clientTotal = clientCores.reduce((a, b) => a + b, 0);
  const output = {
    label: args.label, url: args.url, proto: args.proto, connections: args.connections, streamsPerConnection: args.streams,
    concurrency: args.connections * args.streams, procs, warmupS: args.warmupS, durationS: args.durationS, meta,
    requests: count, rps: count / windowS,
    latencyUs: count === 0 ? null : {
      p50: percentile(histogram, count, 50), p90: percentile(histogram, count, 90), p99: percentile(histogram, count, 99),
      p999: percentile(histogram, count, 99.9), max: valueOf(maxBucket), mean: sumUs / count,
    },
    errors,
    firstFailure: childResults.find((result) => result.firstFailure)?.firstFailure ?? null,
    statusSample: childResults.find((result) => result.statusSample)?.statusSample ?? null,
    drain: childResults.map((result) => result.reason),
    cpu: {
      clientCoresPerProcess: clientCores, clientCoresTotal: clientTotal, clientCoresMax: Math.max(...clientCores),
      serverCores, machineBusyCores, machineCpus: cpus,
      otherCores: machineBusyCores === null || serverCores === null ? null : machineBusyCores - serverCores - clientTotal,
      loadavgBefore: loadavg,
    },
    server: { ...server, logPattern: args.logPattern || null },
    finishedAt: new Date().toISOString(),
  };
  const text = `${JSON.stringify(output, null, 2)}\n`;
  if (args.out) fs.writeFileSync(args.out, text);
  else process.stdout.write(text);
  const failed = Object.values(errors).some((value) => value > 0) || count === 0;
  process.exitCode = failed ? 3 : 0;
}

if (process.argv[2] === "--child") runChild();
else runParent(parseArgs(process.argv.slice(2))).catch((error) => { console.error(`loadgen: ${error.message}`); process.exit(1); });
