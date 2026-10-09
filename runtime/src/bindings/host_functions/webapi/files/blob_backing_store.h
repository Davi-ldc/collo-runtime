// One heap allocation a Blob keeps alive, as the object URL registry (`ColloBlobObjectURLRegistry` in
// jsc/runtime/state.h) counts it against its byte budget. The struct has its own header because state.h includes it
// without the cell classes of blob.h. Plain data, used on the VM thread.

#pragma once

#include <cstddef>

namespace Collo::HostFunctions {

// `key` is the address of a BlobStorage or BlobBytes and only identifies the allocation: the registry never
// dereferences it, and charges `bytes` once per key however many URLs share it. A key cannot be reused while it is
// registered, because the registry entry holds the Blob, which keeps the allocation alive. A null key makes the
// registry refuse the insert.
struct BlobObjectURLBackingStore {
    const void* key { nullptr };
    size_t bytes { 0 };
};

} // namespace Collo::HostFunctions
