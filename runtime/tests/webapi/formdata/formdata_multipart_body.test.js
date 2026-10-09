// FormData -> multipart/form-data BodyInit serialization.
//
// Spec: WHATWG Fetch "multipart/form-data encoding algorithm" + HTML escaping
// of name/filename (CR -> %0D, LF -> %0A, '"' -> %22; UTF-8 field names).
// Contract derived from Bun v1.3.14 (reference/bun-v1.3.14): passing a FormData
// as a Request/Response body produces a multipart body and a
// `multipart/form-data; boundary=...` Content-Type, and round-trips through
// `.formData()`.

const decoder = new TextDecoder();
const MATERIALIZED_BODY_LIMIT = 4 * 1024 * 1024;

async function bodyText(init) {
  return await new Response(init).text();
}

function boundaryOf(response) {
  const type = response.headers.get("content-type");
  assert(type, "multipart body must set a content-type");
  const match = /^multipart\/form-data; boundary=(.+)$/.exec(type);
  assert(match, `content-type should be multipart/form-data with a boundary, got: ${type}`);
  return match[1];
}

function assertQuotaExceeded(label, fn) {
  const error = assert.throws(fn, DOMException, label);
  assert.equal(error.name, "QuotaExceededError", `${label} error name`);
}

function multipartStringFieldOverhead(boundaryLength, name) {
  const boundary = "x".repeat(boundaryLength);
  return (
    `--${boundary}\r\n`.length +
    `Content-Disposition: form-data; name="${name}"\r\n\r\n`.length +
    "\r\n".length +
    `--${boundary}--\r\n`.length
  );
}

function multipartFileFieldOverhead(boundaryLength, name, filename, contentType = "application/octet-stream") {
  const boundary = "x".repeat(boundaryLength);
  return (
    `--${boundary}\r\n`.length +
    `Content-Disposition: form-data; name="${name}"; filename="${filename}"\r\n`.length +
    `Content-Type: ${contentType}\r\n\r\n`.length +
    "\r\n".length +
    `--${boundary}--\r\n`.length
  );
}

describe("FormData multipart body", () => {
  test("string field round-trips through Content-Type and parser", async () => {
    const form = new FormData();
    form.append("greeting", "hello world");
    form.append("greeting", "second value");
    form.append("other", "x");

    const response = new Response(form);
    const boundary = boundaryOf(response);
    assert(boundary.startsWith("----ColloFormBoundary"), `unexpected boundary: ${boundary}`);

    const text = await response.clone().text();
    assert(text.includes(`--${boundary}\r\n`), "body must contain the opening delimiter");
    assert(text.endsWith(`--${boundary}--\r\n`), "body must end with the closing delimiter");
    assert(
      text.includes('Content-Disposition: form-data; name="greeting"\r\n\r\nhello world\r\n'),
      "string part framing must match the spec",
    );

    // Round-trip: parse the produced body back into FormData.
    const parsed = await response.formData();
    assert.deepEqual(parsed.getAll("greeting"), ["hello world", "second value"]);
    assert.equal(parsed.get("other"), "x");
  });

  test("File entry emits filename, Content-Type and bytes, and round-trips", async () => {
    const form = new FormData();
    const file = new File(["file body bytes"], "report.txt", { type: "text/plain" });
    form.append("upload", file);
    // A bare Blob value gets the default filename "blob" and octet-stream type.
    form.append("raw", new Blob([new Uint8Array([1, 2, 3])]));

    const response = new Response(form);
    const boundary = boundaryOf(response);
    const text = await response.clone().text();
    assert(
      text.includes(
        `Content-Disposition: form-data; name="upload"; filename="report.txt"\r\nContent-Type: text/plain\r\n\r\nfile body bytes\r\n`,
      ),
      "file part framing must include filename and Content-Type",
    );
    assert(
      text.includes('Content-Disposition: form-data; name="raw"; filename="blob"\r\nContent-Type: application/octet-stream\r\n'),
      "blob value defaults to filename=blob and application/octet-stream",
    );

    const parsed = await response.formData();
    const upload = parsed.get("upload");
    assert(upload instanceof File, "upload must parse back as a File");
    assert.equal(upload.name, "report.txt");
    assert.equal(upload.type, "text/plain");
    assert.equal(await upload.text(), "file body bytes");

    const raw = parsed.get("raw");
    assert(raw instanceof File, "raw blob must parse back as a File");
    assert.deepEqual(Array.from(new Uint8Array(await raw.arrayBuffer())), [1, 2, 3]);
  });

  test("binary File bytes survive round-trip byte-for-byte", async () => {
    const bytes = new Uint8Array(256);
    for (let i = 0; i < 256; i++) bytes[i] = i;
    const form = new FormData();
    form.append("blob", new File([bytes], "raw.bin", { type: "application/octet-stream" }));

    const parsed = await new Response(form).formData();
    const file = parsed.get("blob");
    assert(file instanceof File);
    assert.deepEqual(Array.from(new Uint8Array(await file.arrayBuffer())), Array.from(bytes));
  });

  test("name and filename escape CR, LF and double-quote", async () => {
    const form = new FormData();
    form.append('na"me\r\n', "v");
    form.append("file", new File(["x"], 'qu"ote\r\nname'));

    const text = await bodyText(form);
    // " -> %22, CR -> %0D, LF -> %0A; no raw control bytes leak into headers.
    assert(text.includes('name="na%22me%0D%0A"'), `escaped field name missing: ${JSON.stringify(text)}`);
    assert(text.includes('filename="qu%22ote%0D%0Aname"'), "escaped filename missing");
    // Header-injection guard: the escaped header line must not contain a raw
    // CRLF inside the parameter values.
    const dispositionLines = text.split("\r\n").filter(l => l.startsWith("Content-Disposition:"));
    for (const line of dispositionLines)
      assert(!/[\r\n]/.test(line.slice("Content-Disposition:".length).replace(/%0D|%0A/g, "")), "no raw CR/LF in header");
  });

  test("Response objects passed as BodyInit are stringified", async () => {
    const form = new FormData();
    form.append("a", "b");
    assert.equal(await bodyText(new Response(form)), "[object Response]");
  });

  test("UTF-8 field names and values are preserved", async () => {
    const form = new FormData();
    form.append("名前", "値🌍");
    const parsed = await new Response(form).formData();
    assert.equal(parsed.get("名前"), "値🌍");
  });

  test("empty string field value round-trips", async () => {
    const form = new FormData();
    form.append("k", "");
    const parsed = await new Response(form).formData();
    assert.equal(parsed.get("k"), "");
  });

  test("File with a non-printable type falls back to application/octet-stream", async () => {
    // A Blob/File type with a control character is stripped to "" by the Blob
    // type normalizer, so the multipart part must default to octet-stream (this
    // is also the header-injection guard for the part Content-Type).
    const form = new FormData();
    form.append("f", new File(["x"], "n.bin", { type: "text/\r\nplain" }));
    const text = await new Response(form).text();
    assert(
      text.includes('filename="n.bin"\r\nContent-Type: application/octet-stream\r\n'),
      `non-printable type must fall back to octet-stream: ${JSON.stringify(text)}`,
    );
    assert(!/Content-Type: text/.test(text), "stripped type must not leak into the header");
  });

  test("empty FormData yields just the closing delimiter", async () => {
    const form = new FormData();
    const response = new Response(form);
    const boundary = boundaryOf(response);
    assert.equal(await response.clone().text(), `--${boundary}--\r\n`);
    assert.deepEqual(Array.from(await response.formData()), []);
  });

  test("boundary is fresh per body and unguessable", async () => {
    const a = boundaryOf(new Response(new FormData()));
    const b = boundaryOf(new Response(new FormData()));
    assert(a !== b, "each serialization must use a fresh boundary");
    assert(a.length >= "----ColloFormBoundary".length + 16, "boundary must carry entropy");
  });

  test("explicit content-type set by the caller is not overwritten", async () => {
    const form = new FormData();
    form.append("a", "b");
    const response = new Response(form, { headers: { "content-type": "text/custom" } });
    assert.equal(response.headers.get("content-type"), "text/custom");
  });

  test("FormData request body sets multipart Content-Type and round-trips", async () => {
    const form = new FormData();
    form.append("field", "value");
    form.append("doc", new File(["doc"], "d.txt", { type: "text/plain" }));
    const request = new Request("https://example.com/upload", { method: "POST", body: form });
    const boundary = boundaryOf(request);
    assert(boundary.startsWith("----ColloFormBoundary"));
    const parsed = await request.formData();
    assert.equal(parsed.get("field"), "value");
    assert.equal(await parsed.get("doc").text(), "doc");
  });

  test("FormData BodyInit rejects serialized bodies over the materialized body limit", () => {
    const textForm = new FormData();
    textForm.append("payload", "x".repeat(MATERIALIZED_BODY_LIMIT));
    assertQuotaExceeded("oversized Response FormData string field", () => new Response(textForm));
    assertQuotaExceeded("oversized Request FormData string field", () => new Request("https://example.com/upload", {
      method: "POST",
      body: textForm,
    }));

    const fileForm = new FormData();
    fileForm.append("file", new File([new Uint8Array(MATERIALIZED_BODY_LIMIT)], "payload.bin"));
    assertQuotaExceeded("oversized Response FormData file field", () => new Response(fileForm));
  });

  test("FormData BodyInit accepts exactly the materialized body limit and rejects one byte over", async () => {
    const boundaryLength = boundaryOf(new Response(new FormData())).length;

    const stringName = "payload";
    const stringOverhead = multipartStringFieldOverhead(boundaryLength, stringName);
    const exactStringForm = new FormData();
    exactStringForm.append(stringName, "x".repeat(MATERIALIZED_BODY_LIMIT - stringOverhead));
    assert.equal((await new Response(exactStringForm).bytes()).byteLength, MATERIALIZED_BODY_LIMIT);

    const overStringForm = new FormData();
    overStringForm.append(stringName, "x".repeat(MATERIALIZED_BODY_LIMIT - stringOverhead + 1));
    assertQuotaExceeded("one-byte-over string field", () => new Response(overStringForm));

    const fileName = "payload.bin";
    const fileOverhead = multipartFileFieldOverhead(boundaryLength, "file", fileName);
    const exactFileForm = new FormData();
    exactFileForm.append("file", new File([new Uint8Array(MATERIALIZED_BODY_LIMIT - fileOverhead)], fileName));
    assert.equal(boundaryOf(new Response(exactFileForm)).length, boundaryLength);

    const overFileForm = new FormData();
    overFileForm.append("file", new File([new Uint8Array(MATERIALIZED_BODY_LIMIT - fileOverhead + 1)], fileName));
    assertQuotaExceeded("one-byte-over file field", () => new Response(overFileForm));
  });
});
