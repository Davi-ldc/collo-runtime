// How long a WebCrypto operation may hold the VM thread, where it runs inline: the guard every operation checks the
// clock through, the estimates it uses before starting, and the cap on PBKDF2's work.
//
// Native work cannot be stopped. The sentinel ends an owner's JavaScript at its deadline or when its CPU budget ends,
// but a native call runs on until it returns, and while it runs the worker's loop answers no other request's deadline.
// So an operation never trusts an estimate to stay inside those limits: one that can run long checks the clock itself
// while it works, through a `TimeGuard` that asks the worker runtime how long native work may still keep the VM thread
// (`collo_runtime_native_time_left_ns` in abi.h). That is the least of every live owner's time to its wall deadline
// and the calling owner's CPU left, so the operation stops, with an OperationError, before any request of the worker
// misses its deadline, not only before its caller does. Digests, HMAC, the AES modes, PBKDF2 and HKDF check between
// slices of their input; RSA key generation checks from BoringSSL's progress callback. A step that cannot check, a
// private-key RSA operation, an EC operation, Ed25519 over its message, AES key wrap, is short by construction: its
// input is bounded (types.h) and it starts only when the time left covers a multiple of its estimate.
//
// The estimates come from the WebCrypto probe in `report/bench-before-simplify/probes-timings-loaded.md`, run with
// BoringSSL alone on one pinned core of the reference machine under load. They decide when a guarded operation refuses
// to start because it would most likely be stopped anyway, how often it looks at the clock, and whether an
// uninterruptible step may start; none of them is trusted to bound a running operation.

#pragma once

#include "host_functions/webapi/crypto/types.h"

#include <wtf/Noncopyable.h>
#include <wtf/text/ASCIILiteral.h>

#include <cstddef>
#include <cstdint>

namespace JSC {
class JSGlobalObject;
class ThrowScope;
}

namespace Collo::HostFunctions::WebCrypto {

// The most estimated work an operation does between two looks at the clock, and the most it does without one at all:
// an operation estimated below this never asks, since a native call that short is no worse than the JavaScript around
// it. Slices are sized so that one stays well below it.
constexpr double unchecked_work_ns_max = 1'000'000;
// An operation keeps working only while the time left exceeds this reserve. It covers the work up to the next look at
// the clock, at most `unchecked_work_ns_max` of estimated work or one step of RSA key generation (a Miller-Rabin round,
// about 3 ms at 4096 bits on the reference machine), on a core several times slower than the reference one.
constexpr double time_reserve_ns = 20'000'000;
// A step that cannot look at the clock starts only when the time left covers this many times its estimate plus the
// reserve: the estimates are p95 or largest times of one reference core, and a worker's core may be slower or shared
// with the engine's own threads.
constexpr double uninterruptible_margin = 4;

// The clock checks of one WebCrypto operation, on the VM thread. It keeps no JavaScript value, so the primitives in
// `ops/` take it. Once it refuses, it refuses every later call, and the operation fails with OperationError
// (`throwOperationFailed`).
class TimeGuard {
    WTF_MAKE_NONCOPYABLE(TimeGuard);

public:
    // `host_runtime` is the worker runtime of the VM; null, as on a VM with no runtime attached such as the zygote's
    // or a bindings test's, places no limit.
    explicit TimeGuard(void* host_runtime)
        : m_host_runtime(host_runtime)
    {
    }

    // Before an operation that checks this guard while it runs: whether the time left covers `expected_ns` plus the
    // reserve, so the work is not likely thrown away when the guard stops it.
    bool startFits(double expected_ns);
    // Before a step that cannot check this guard, whose worst case is `worst_case_ns`: whether the time left covers
    // `uninterruptible_margin` times it plus the reserve.
    bool uninterruptibleFits(double worst_case_ns);
    // Before each slice of a running operation, estimated at `slice_ns`: looks at the clock once the estimated work
    // since the last look reaches `unchecked_work_ns_max`, and refuses when the time left no longer covers the slice
    // plus the reserve.
    bool spend(double slice_ns);
    // Looks at the clock now, for a step whose work no estimate describes, such as a callback of RSA key generation:
    // refuses when the time left no longer covers the reserve.
    bool check();
    bool ranOut() const { return m_ran_out; }

private:
    bool hasTimeLeft(double needed_ns);

    void* m_host_runtime;
    double m_unchecked_ns { 0 };
    bool m_ran_out { false };
};

// The worker runtime of `global_object`'s VM, for its operations' guards; null when none is attached.
void* hostRuntimeOf(JSC::JSGlobalObject*);

// Throws the OperationError of a guard that refused and returns false, or returns true. For the checks before an
// operation and before an uninterruptible step.
bool requireStartFits(JSC::JSGlobalObject*, JSC::ThrowScope&, TimeGuard&, double expected_ns);
bool requireUninterruptibleFits(JSC::JSGlobalObject*, JSC::ThrowScope&, TimeGuard&, double worst_case_ns);
// The OperationError of a primitive that failed: one that names the time when `guard` refused, a plain one otherwise.
void throwOperationFailed(JSC::JSGlobalObject*, JSC::ThrowScope&, const TimeGuard&);
// The OperationError of an input past one of the bounds in types.h.
void throwInputTooLarge(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral what);

// How AES runs over its input, which sets its cost per byte.
enum class AesMode : uint8_t {
    // BoringSSL's EVP ciphers: GCM, and CTR whose counter is the whole block.
    Gcm,
    CtrWholeBlock,
    Cbc,
    // One AES block per 16 bytes through AES_encrypt, for a CTR counter narrower than the block.
    CtrPartialBlock,
    // One AES block per byte.
    Cfb8,
    // RFC 3394: six AES blocks per 8 bytes.
    Kw,
};

double digestWorstCaseNs(WebCryptoHash, size_t input_bytes);
// HMAC hashes the key, when it is longer than a block, and the input.
double hmacWorstCaseNs(WebCryptoHash, size_t key_bytes, size_t input_bytes);
double aesWorstCaseNs(AesMode, size_t input_bytes);
// AES-GCM over `input_bytes`, with the GHASH of its additional data and of an IV that is not 12 bytes long.
double aesGcmWorstCaseNs(size_t input_bytes, size_t additional_data_bytes, size_t iv_bytes);
// A signature or decryption with the private key, and a verification or encryption with the public key, of a key
// whose public exponent has at most 33 bits (`createAsymmetricKey` in keys.h refuses any other).
double rsaPrivateWorstCaseNs(size_t modulus_bits);
double rsaPublicWorstCaseNs(size_t modulus_bits);
// The median time of RSA key generation, which only decides whether to start: its time is random and the generation
// checks the clock as it goes.
double rsaGenerateExpectedNs(uint32_t modulus_bits);
// ECDSA without the message's digest, which the caller adds.
double ecdsaSignWorstCaseNs(CryptoKeyNamedCurve);
double ecdsaVerifyWorstCaseNs(CryptoKeyNamedCurve);
// ECDH and X25519 key agreement.
double keyAgreementWorstCaseNs(CryptoKeyNamedCurve);
// A key pair on an EC or OKP curve.
double curveGenerateWorstCaseNs(CryptoKeyNamedCurve);
double ed25519SignWorstCaseNs(size_t input_bytes);
double ed25519VerifyWorstCaseNs(size_t input_bytes);
// PBKDF2's work: one HMAC per iteration for each output block of the hash's size, the salt hashed once per output
// block in the first of those, and the password hashed once when it is longer than the hash's block.
double pbkdf2WorkNs(WebCryptoHash, size_t password_bytes, size_t salt_bytes, uint32_t iterations, size_t output_bytes);
// `iterations` of PBKDF2 for one output block, past the first: the estimate of one slice of the derivation.
double pbkdf2IterationsNs(WebCryptoHash, uint32_t iterations);
// HKDF hashes its key and salt once, its info once per output block, and computes one HMAC per output block.
double hkdfWorstCaseNs(WebCryptoHash, size_t key_bytes, size_t salt_bytes, size_t info_bytes, size_t output_bytes);

// The most work one PBKDF2 derivation may do, deriveBits and deriveKey alike: what 1,000,000 SHA-256 iterations cost
// for one output block with a salt that fits the first HMAC's block, so a slower hash, more output blocks or a longer
// salt or password allow fewer iterations. A larger derivation is an OperationError whatever time is left; within the
// cap, the derivation still checks the clock as it goes.
double pbkdf2WorkNsMax();

}
