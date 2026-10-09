import { describe, expect, test } from "bun:test";

// WebAPI/server-profile subset from:
// reference/bun-v1.3.14/test/js/web/streams/compression.test.ts
//
// Excluded from this compat fixture:
// - zstd, which is a Bun extension outside the current WebAPI compression set.
// - Buffer.alloc(), replaced by equivalent string inputs so this suite stays
//   Buffer-free.

describe("CompressionStream and DecompressionStream", () => {
  describe("brotli", () => {
    test("compresses data with brotli", async () => {
      const input = "Hello, Bun! This is a test string for brotli compression.";
      const encoder = new TextEncoder();
      const data = encoder.encode(input);

      const compressionStream = new CompressionStream("brotli");
      const writer = compressionStream.writable.getWriter();
      writer.write(data);
      writer.close();

      const compressedChunks = [];
      const reader = compressionStream.readable.getReader();

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        compressedChunks.push(value);
      }

      expect(compressedChunks.length).toBeGreaterThan(0);
      const totalLength = compressedChunks.reduce((acc, chunk) => acc + chunk.length, 0);
      expect(totalLength).toBeGreaterThan(0);
    });

    test("decompresses brotli data", async () => {
      const input = "Hello, Bun! This is a test string for brotli decompression.";
      const encoder = new TextEncoder();
      const decoder = new TextDecoder();
      const data = encoder.encode(input);

      const compressionStream = new CompressionStream("brotli");
      const writer = compressionStream.writable.getWriter();
      writer.write(data);
      writer.close();

      const compressedChunks = [];
      const reader = compressionStream.readable.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        compressedChunks.push(value);
      }

      const totalLength = compressedChunks.reduce((acc, chunk) => acc + chunk.length, 0);
      const compressed = new Uint8Array(totalLength);
      let offset = 0;
      for (const chunk of compressedChunks) {
        compressed.set(chunk, offset);
        offset += chunk.length;
      }

      const decompressionStream = new DecompressionStream("brotli");
      const decompWriter = decompressionStream.writable.getWriter();
      decompWriter.write(compressed);
      decompWriter.close();

      const decompressedChunks = [];
      const decompReader = decompressionStream.readable.getReader();
      while (true) {
        const { done, value } = await decompReader.read();
        if (done) break;
        decompressedChunks.push(value);
      }

      const decompressedLength = decompressedChunks.reduce((acc, chunk) => acc + chunk.length, 0);
      const decompressed = new Uint8Array(decompressedLength);
      offset = 0;
      for (const chunk of decompressedChunks) {
        decompressed.set(chunk, offset);
        offset += chunk.length;
      }

      const output = decoder.decode(decompressed);
      expect(output).toBe(input);
    });

    test("round-trip compression with brotli", async () => {
      const testData = [
        "Simple string",
        "A".repeat(1000),
        "Mixed 123 !@# symbols",
        "",
        JSON.stringify({ nested: { object: "value" } }),
      ];

      for (const input of testData) {
        const encoder = new TextEncoder();
        const decoder = new TextDecoder();
        const data = encoder.encode(input);

        const compressed = await new Response(
          new Blob([data]).stream().pipeThrough(new CompressionStream("brotli")),
        ).arrayBuffer();

        const decompressed = await new Response(
          new Blob([compressed]).stream().pipeThrough(new DecompressionStream("brotli")),
        ).arrayBuffer();

        const output = decoder.decode(decompressed);
        expect(output).toBe(input);
      }
    });
  });

  describe("all formats", () => {
    test("works with all supported WebAPI compression formats", async () => {
      const formats = [
        "gzip",
        "deflate",
        "deflate-raw",
        "brotli",
      ];

      const input = "Test data for all compression formats!";
      const encoder = new TextEncoder();
      const decoder = new TextDecoder();
      const data = encoder.encode(input);

      for (const format of formats) {
        const compressed = await new Response(
          new Blob([data]).stream().pipeThrough(new CompressionStream(format)),
        ).arrayBuffer();

        const decompressed = await new Response(
          new Blob([compressed]).stream().pipeThrough(new DecompressionStream(format)),
        ).arrayBuffer();

        const output = decoder.decode(decompressed);
        expect(output).toBe(input);
      }
    });
  });
});
