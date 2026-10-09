// Collo-only.

bench("headers.construct-and-get", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const headers = new Headers({
      "Content-Type": "text/plain",
      "X-Request-Id": "abc",
      "Accept": "*/*",
    });
    checksum += headers.get("content-type").length;
    checksum += headers.has("x-request-id");
  }
  return checksum;
}, { iterations: 70000, warmup: 5000 });

bench("headers.append-set-iterate", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const headers = new Headers();
    headers.append("x-a", "1");
    headers.append("x-a", "2");
    headers.set("content-type", "application/json");
    for (const [name, value] of headers)
      checksum += name.length + value.length;
  }
  return checksum;
}, { iterations: 60000, warmup: 5000 });

bench("headers.get-set-cookie", iterations => {
  const headers = new Headers([
    ["set-cookie", "a=1"],
    ["set-cookie", "b=2"],
    ["set-cookie", "c=3"],
  ]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const cookies = headers.getSetCookie();
    checksum += cookies.length;
    checksum += cookies[i % cookies.length].length;
  }
  return checksum;
}, { iterations: 140000, warmup: 10000 });

bench("headers.to-json-and-count", iterations => {
  const headers = new Headers([
    ["x-request-id", "abc"],
    ["set-cookie", "a=1"],
    ["set-cookie", "b=2"],
    ["accept", "text/plain"],
    ["accept", "application/json"],
  ]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const json = headers.toJSON();
    checksum += headers.count;
    checksum += json.accept.length;
  }
  return checksum;
}, { iterations: 100000, warmup: 10000 });
