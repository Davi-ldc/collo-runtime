// Collo-only.

bench("url.construct-absolute-http", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const url = new URL("https://user:pass@example.com:8443/a/b?x=1#hash");
    checksum += url.protocol.length;
    checksum += url.host.length;
    checksum += url.pathname.length;
    checksum += url.search.length;
  }
  return checksum;
}, { iterations: 80000, warmup: 5000 });

bench("url.mutate-and-serialize", iterations => {
  const url = new URL("https://example.com/a?x=1");
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    url.pathname = "/p/" + (i & 255);
    url.searchParams.set("x", String(i & 31));
    checksum += url.href.length;
  }
  return checksum;
}, { iterations: 120000, warmup: 5000 });

bench("url.parse-static", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const url = URL.parse("/item/" + (i & 255), "https://example.com/base");
    checksum += url.href.length;
    checksum += URL.parse("http://[") === null;
  }
  return checksum;
}, { iterations: 80000, warmup: 5000 });

bench("url.blob-object-url", iterations => {
  const blob = new Blob(["hello"], { type: "text/plain" });
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const url = URL.createObjectURL(blob);
    checksum += url.length;
    URL.revokeObjectURL(url);
  }
  return checksum;
}, { iterations: 60000, warmup: 5000 });
