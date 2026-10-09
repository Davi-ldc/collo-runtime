// Collo-only.

bench("formdata.append-string-get", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const form = new FormData();
    form.append("foo", "bar");
    form.append("foo", "baz");
    checksum += form.get("foo").length + form.getAll("foo").length;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("formdata.set-duplicate", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const form = new FormData();
    form.append("a", "1");
    form.append("a", "2");
    form.set("a", "3");
    form.append("b", "4");
    checksum += form.get("a").charCodeAt(0) + Array.from(form.keys()).length;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("formdata.iterate-entries", iterations => {
  const form = new FormData();
  for (let i = 0; i < 16; i++)
    form.append(`k${i}`, `v${i}`);

  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    for (const [name, value] of form)
      checksum += name.length + value.length;
  }
  return checksum;
}, { iterations: 50000, warmup: 2000 });

bench("formdata.append-blob-custom-name", iterations => {
  const blob = new Blob(["hello"], { type: "text/plain" });
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const form = new FormData();
    form.append("file", blob, "hello.txt");
    const file = form.get("file");
    checksum += file.size + file.name.length + file.type.length;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("formdata.for-each", iterations => {
  const form = new FormData();
  for (let i = 0; i < 8; i++)
    form.append(`k${i}`, `v${i}`);

  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    form.forEach((value, name) => {
      checksum += value.length + name.length;
    });
  }
  return checksum;
}, { iterations: 50000, warmup: 2000 });

bench("formdata.to-json-and-length", iterations => {
  const form = new FormData();
  form.append("a", "1");
  form.append("a", "2");
  form.append("b", "3");

  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const json = form.toJSON();
    checksum += form.length;
    checksum += json.a.length;
    checksum += json.b.length;
  }
  return checksum;
}, { iterations: 100000, warmup: 10000 });

bench("formdata.from-urlencoded", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const form = FormData.from("a=1&b=2&a=3");
    checksum += form.length;
    checksum += form.getAll("a").length;
  }
  return checksum;
}, { iterations: 60000, warmup: 5000 });
