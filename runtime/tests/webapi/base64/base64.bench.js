// Collo-only.

bench("base64.btoa-ascii", iterations => {
  const text = "hello world ".repeat(12);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += btoa(text).length;
  return checksum;
}, { iterations: 160000, warmup: 10000 });

bench("base64.btoa-latin1", iterations => {
  const text = "\x80\x81\xe9".repeat(32);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += btoa(text).length;
  return checksum;
}, { iterations: 140000, warmup: 10000 });

bench("base64.atob-padded", iterations => {
  const encoded = btoa("hello world ".repeat(12));
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += atob(encoded).length;
  return checksum;
}, { iterations: 160000, warmup: 10000 });

bench("base64.atob-whitespace", iterations => {
  const encoded = "  " + btoa("hello world ".repeat(12)).replace(/.{8}/g, "$&\n\t") + "  ";
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += atob(encoded).length;
  return checksum;
}, { iterations: 120000, warmup: 8000 });

bench("base64.roundtrip", iterations => {
  const text = "auth:user:pass ".repeat(8);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += atob(btoa(text)).length;
  return checksum;
}, { iterations: 120000, warmup: 8000 });
