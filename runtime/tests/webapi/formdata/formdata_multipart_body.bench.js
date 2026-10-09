// Collo-only.

bench("formdata.multipart-response-text", async iterations => {
  let checksum = 0;
  for (let index = 0; index < iterations; index++) {
    const form = new FormData();
    form.append("field", `value-${index & 15}`);
    form.append("doc", new File(["document"], "doc.txt", { type: "text/plain" }));
    const response = new Response(form);
    checksum += response.headers.get("content-type").length;
    checksum += (await response.text()).length;
  }
  return checksum;
}, { iterations: 3000, warmup: 200 });

bench("formdata.multipart-roundtrip", async iterations => {
  let checksum = 0;
  for (let index = 0; index < iterations; index++) {
    const form = new FormData();
    form.append("name", "Collo");
    form.append("blob", new File([new Uint8Array([index & 255, 2, 3])], "raw.bin"));
    const parsed = await new Response(form).formData();
    checksum += parsed.get("name").length;
    checksum += (await parsed.get("blob").arrayBuffer()).byteLength;
  }
  return checksum;
}, { iterations: 2000, warmup: 100 });

bench("formdata.multipart-escaped-names", async iterations => {
  let checksum = 0;
  for (let index = 0; index < iterations; index++) {
    const form = new FormData();
    form.append(`na"me\r\n${index & 7}`, "value");
    form.append("file", new File(["x"], `qu"ote\r\n${index & 7}`));
    checksum += (await new Response(form).text()).length;
  }
  return checksum;
}, { iterations: 3000, warmup: 200 });
