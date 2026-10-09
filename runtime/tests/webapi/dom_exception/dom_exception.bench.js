// Collo-only.

bench("dom-exception.construct-abort-error", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const err = new DOMException("aborted", "AbortError");
    checksum += err.code;
    checksum += err.name.length;
    checksum += err.message.length;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("dom-exception.constants", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    checksum += DOMException.ABORT_ERR;
    checksum += DOMException.TIMEOUT_ERR;
    checksum += DOMException.prototype.DATA_CLONE_ERR;
  }
  return checksum;
}, { iterations: 500000, warmup: 10000 });
