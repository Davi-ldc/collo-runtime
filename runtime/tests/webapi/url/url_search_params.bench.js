// Collo-only.

bench("url-search-params.parse-and-iterate", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const params = new URLSearchParams("a=1&b=2&c=3&a=4");
    checksum += params.get("a").length;
    checksum += params.getAll("a").length;
    for (const [key, value] of params)
      checksum += key.length + value.length;
  }
  return checksum;
}, { iterations: 60000, warmup: 5000 });

bench("url-search-params.append-set-sort", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const params = new URLSearchParams();
    params.append("z", "1");
    params.append("a", "2");
    params.set("z", String(i & 7));
    params.sort();
    checksum += params.toString().length;
  }
  return checksum;
}, { iterations: 80000, warmup: 5000 });

bench("url-search-params.to-json-and-size", iterations => {
  const params = new URLSearchParams("a=1&b=2&a=3&empty=");
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const json = params.toJSON();
    checksum += params.size;
    checksum += json.a.length;
    checksum += json.b.length;
  }
  return checksum;
}, { iterations: 100000, warmup: 10000 });
