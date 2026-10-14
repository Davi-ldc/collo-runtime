// The guard and the estimates declared in budget.h, on the VM thread. Every time below is in nanoseconds and comes from
// a row of `report/bench-before-simplify/probes-timings-loaded.md`, named beside it; a time per MiB is that row's time
// over 1 MiB of input. A constant the probe has no row for says which measured row bounds it and why.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/budget.h"

#include "host_functions/runtime/bridge.h"
#include "jsc/runtime/js_support.h"

#include <wtf/text/MakeString.h>

#include <array>

namespace Collo::HostFunctions::WebCrypto {
namespace {

    constexpr double bytes_per_mib = 1024.0 * 1024.0;

    struct HashCost {
        // A digest over 1 MiB.
        double digest_ns_per_mib;
        // One HMAC of one block, the unit of PBKDF2's work: one iteration for one output block, which runs the hash's
        // compression function twice.
        double hmac_block_ns;
    };

    // Indexed by WebCryptoHash. Digests: the "SHA-1/SHA-256/SHA-512 digest, 1 MiB" rows. HMAC blocks: the "SHA-1,
    // 100000 iterations", "SHA-256, 1000000 iterations", "SHA-384, 100000 iterations" and "SHA-512, 100000
    // iterations" PBKDF2 rows over their iteration counts. SHA-224 runs SHA-256's compression function and SHA-384
    // runs SHA-512's, so each takes its sibling's time. The probe has no SHA-3 row: a SHA-3 hash runs the
    // Keccak-f[1600] permutation in portable C, unaccelerated, and is given twice SHA-512's time.
    constexpr std::array<HashCost, 9> hash_costs { {
        { 1'246'000, 268.64 },
        { 1'112'000, 247.011 },
        { 1'112'000, 247.011 },
        { 5'058'000, 879.72 },
        { 5'058'000, 988.66 },
        { 10'116'000, 1977.32 },
        { 10'116'000, 1977.32 },
        { 10'116'000, 1977.32 },
        { 10'116'000, 1977.32 },
    } };
    static_assert(hash_costs.size() == static_cast<size_t>(WebCryptoHash::SHA3_512) + 1);

    // AES per MiB, indexed by AesMode. GCM: the "AES-256-GCM encrypt, 1 MiB" row. The probe has no row for the other
    // modes. CTR over the whole block is GCM without its GHASH, so GCM's time bounds it. CBC encryption chains its
    // blocks, so AES-NI runs them one after another instead of four at once: four times GCM's time. A partial-block CTR
    // runs one unpipelined block per 16 bytes like CBC plus a loop over each byte: twice CBC's time. 8-bit CFB runs a
    // block for every byte, sixteen times CBC's blocks, and key wrap six blocks for every 8 bytes, twelve times
    // CBC's.
    constexpr std::array<double, 6> aes_ns_per_mib { {
        500'000,
        500'000,
        2'000'000,
        4'000'000,
        32'000'000,
        24'000'000,
    } };
    static_assert(aes_ns_per_mib.size() == static_cast<size_t>(AesMode::Kw) + 1);

    struct RsaCost {
        uint32_t modulus_bits;
        // The "RSA-PSS <bits> sign" and "RSA-PSS <bits> verify" rows, with the exponent 65537 the probe used.
        double private_ns;
        double public_ns;
    };

    // A modulus between two rows takes the larger row's time.
    constexpr std::array<RsaCost, 4> rsa_costs { {
        { 2048, 737'000, 24'000 },
        { 3072, 2'217'000, 44'000 },
        { 4096, 4'891'000, 96'000 },
        { 8192, 39'695'000, 292'000 },
    } };
    static_assert(rsa_costs.back().modulus_bits == rsa_modulus_bits_max);

    struct RsaGenerateCost {
        uint32_t modulus_bits;
        double ns;
    };

    // The median of each "RSA <bits>" generateKey row. A modulus between two rows takes the larger row's time.
    constexpr std::array<RsaGenerateCost, 3> rsa_generate_costs { {
        { 2048, 105'886'000 },
        { 3072, 350'015'000 },
        { 4096, 881'214'000 },
    } };
    static_assert(rsa_generate_costs.back().modulus_bits == rsa_generate_modulus_bits_max);

    struct CurveCost {
        double ecdsa_sign_ns;
        double ecdsa_verify_ns;
        double agreement_ns;
        double generate_ns;
    };

    // Indexed by CryptoKeyNamedCurve. EC: the "ECDSA <curve> sign", "verify" and "generateKey" rows. The probe has no
    // ECDH row: an agreement multiplies one point where a verification multiplies two, so the verification's time
    // bounds it. Ed25519: the "Ed25519 generateKey" row; X25519's generation and agreement multiply one point on the
    // same curve, so they take that time too. Neither OKP curve signs with ECDSA.
    constexpr std::array<CurveCost, 6> curve_costs { {
        { 0, 0, 0, 0 },
        { 66'000, 208'000, 208'000, 27'000 },
        { 1'090'000, 1'102'000, 1'102'000, 939'000 },
        { 2'602'000, 2'784'000, 2'784'000, 2'175'000 },
        { 0, 0, 23'000, 23'000 },
        { 0, 0, 23'000, 23'000 },
    } };
    static_assert(curve_costs.size() == static_cast<size_t>(CryptoKeyNamedCurve::X25519) + 1);

    // The "Ed25519 sign, 1 MiB message" and "Ed25519 verify, 1 MiB message" rows, which include the fixed cost.
    constexpr double ed25519_sign_ns_per_mib = 7'486'000;
    constexpr double ed25519_verify_ns_per_mib = 8'089'000;

    double overBytes(double ns_per_mib, size_t bytes)
    {
        return ns_per_mib * (static_cast<double>(bytes) / bytes_per_mib);
    }

    const HashCost& hashCost(WebCryptoHash hash) { return hash_costs[static_cast<size_t>(hash)]; }

    const CurveCost& curveCost(CryptoKeyNamedCurve curve) { return curve_costs[static_cast<size_t>(curve)]; }

    const RsaCost& rsaCost(size_t modulus_bits)
    {
        for (const auto& cost : rsa_costs) {
            if (modulus_bits <= cost.modulus_bits)
                return cost;
        }
        return rsa_costs.back();
    }

    // The output blocks of a hash-based derivation of `output_bytes`.
    double blocksOf(WebCryptoHash hash, size_t output_bytes)
    {
        const size_t digest_bytes = hashSpec(hash).digest_bytes;
        return static_cast<double>((output_bytes + digest_bytes - 1) / digest_bytes);
    }

    // The calls of the hash's compression function over `bytes` of data and the padding that ends it: SHA-1 and SHA-2
    // append at least a 0x80 byte and a length field of 8 bytes for 64-byte blocks or 16 for 128-byte ones, and SHA-3
    // pads at least one byte up to its rate, which `block_bits` holds.
    size_t compressionsOf(WebCryptoHash hash, size_t bytes)
    {
        const size_t block_bytes = hashSpec(hash).block_bits / 8;
        size_t padding_bytes = 1;
        if (hash < WebCryptoHash::SHA3_224)
            padding_bytes += block_bytes == 128 ? 16 : 8;
        return (bytes + padding_bytes + block_bytes - 1) / block_bytes;
    }

    void throwOutOfTime(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        Collo::JscSupport::throwDOMException(global_object, scope, DOMExceptionCode::OperationError,
            "Too little time is left before a deadline or the CPU budget for this operation"_s);
    }

} // namespace

bool TimeGuard::startFits(double expected_ns)
{
    if (m_ran_out)
        return false;
    if (!m_host_runtime || expected_ns <= unchecked_work_ns_max)
        return true;
    if (!hasTimeLeft(expected_ns + time_reserve_ns))
        return false;
    m_unchecked_ns = 0;
    return true;
}

bool TimeGuard::uninterruptibleFits(double worst_case_ns)
{
    if (m_ran_out)
        return false;
    if (!m_host_runtime)
        return true;
    if (m_unchecked_ns + worst_case_ns <= unchecked_work_ns_max) {
        m_unchecked_ns += worst_case_ns;
        return true;
    }
    if (!hasTimeLeft(uninterruptible_margin * worst_case_ns + time_reserve_ns))
        return false;
    m_unchecked_ns = 0;
    return true;
}

bool TimeGuard::spend(double slice_ns)
{
    if (m_ran_out)
        return false;
    if (!m_host_runtime)
        return true;
    if (m_unchecked_ns + slice_ns <= unchecked_work_ns_max) {
        m_unchecked_ns += slice_ns;
        return true;
    }
    if (!hasTimeLeft(slice_ns + time_reserve_ns))
        return false;
    m_unchecked_ns = slice_ns;
    return true;
}

bool TimeGuard::check()
{
    if (m_ran_out)
        return false;
    if (!m_host_runtime)
        return true;
    if (!hasTimeLeft(time_reserve_ns))
        return false;
    m_unchecked_ns = 0;
    return true;
}

bool TimeGuard::hasTimeLeft(double needed_ns)
{
    if (static_cast<double>(collo_runtime_native_time_left_ns(m_host_runtime)) >= needed_ns)
        return true;
    m_ran_out = true;
    return false;
}

void* hostRuntimeOf(JSC::JSGlobalObject* global_object)
{
    // WebCrypto is installed only on Collo globals.
    return Runtime::hostRuntime(uncheckedDowncast<Collo::GlobalObject>(global_object)->owner());
}

bool requireStartFits(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, TimeGuard& guard, double expected_ns)
{
    if (guard.startFits(expected_ns))
        return true;
    throwOutOfTime(global_object, scope);
    return false;
}

bool requireUninterruptibleFits(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, TimeGuard& guard, double worst_case_ns)
{
    if (guard.uninterruptibleFits(worst_case_ns))
        return true;
    throwOutOfTime(global_object, scope);
    return false;
}

void throwOperationFailed(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const TimeGuard& guard)
{
    if (guard.ranOut()) {
        throwOutOfTime(global_object, scope);
        return;
    }
    Collo::JscSupport::throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
}

void throwInputTooLarge(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral what)
{
    Collo::JscSupport::throwDOMException(global_object, scope, DOMExceptionCode::OperationError,
        WTF::makeString(what, " exceeds Collo WebCrypto limits"_s));
}

double digestWorstCaseNs(WebCryptoHash hash, size_t input_bytes)
{
    return overBytes(hashCost(hash).digest_ns_per_mib, input_bytes);
}

double hmacWorstCaseNs(WebCryptoHash hash, size_t key_bytes, size_t input_bytes)
{
    const size_t hashed_key_bytes = key_bytes * 8 > hashSpec(hash).block_bits ? key_bytes : 0;
    return digestWorstCaseNs(hash, hashed_key_bytes) + digestWorstCaseNs(hash, input_bytes)
        + hashCost(hash).hmac_block_ns;
}

double aesWorstCaseNs(AesMode mode, size_t input_bytes)
{
    return overBytes(aes_ns_per_mib[static_cast<size_t>(mode)], input_bytes);
}

double aesGcmWorstCaseNs(size_t input_bytes, size_t additional_data_bytes, size_t iv_bytes)
{
    // GHASH alone costs less per byte than GCM's encryption and GHASH together.
    const size_t hashed_iv_bytes = iv_bytes == 12 ? 0 : iv_bytes;
    return aesWorstCaseNs(AesMode::Gcm, input_bytes) + aesWorstCaseNs(AesMode::Gcm, additional_data_bytes)
        + aesWorstCaseNs(AesMode::Gcm, hashed_iv_bytes);
}

double rsaPrivateWorstCaseNs(size_t modulus_bits) { return rsaCost(modulus_bits).private_ns; }

double rsaPublicWorstCaseNs(size_t modulus_bits) { return rsaCost(modulus_bits).public_ns; }

double rsaGenerateExpectedNs(uint32_t modulus_bits)
{
    for (const auto& cost : rsa_generate_costs) {
        if (modulus_bits <= cost.modulus_bits)
            return cost.ns;
    }
    return rsa_generate_costs.back().ns;
}

double ecdsaSignWorstCaseNs(CryptoKeyNamedCurve curve) { return curveCost(curve).ecdsa_sign_ns; }

double ecdsaVerifyWorstCaseNs(CryptoKeyNamedCurve curve) { return curveCost(curve).ecdsa_verify_ns; }

double keyAgreementWorstCaseNs(CryptoKeyNamedCurve curve) { return curveCost(curve).agreement_ns; }

double curveGenerateWorstCaseNs(CryptoKeyNamedCurve curve) { return curveCost(curve).generate_ns; }

double ed25519SignWorstCaseNs(size_t input_bytes) { return overBytes(ed25519_sign_ns_per_mib, input_bytes); }

double ed25519VerifyWorstCaseNs(size_t input_bytes) { return overBytes(ed25519_verify_ns_per_mib, input_bytes); }

double pbkdf2WorkNs(
    WebCryptoHash hash, size_t password_bytes, size_t salt_bytes, uint32_t iterations, size_t output_bytes)
{
    const auto& spec = hashSpec(hash);
    const double compression_ns = hashCost(hash).hmac_block_ns / 2;
    // HMAC hashes a password longer than the hash's block once, when it is keyed.
    const double password_ns = password_bytes * 8 > spec.block_bits
        ? static_cast<double>(compressionsOf(hash, password_bytes)) * compression_ns
        : 0;
    // The first HMAC of each output block hashes the salt and the block's 4-byte index where every later one hashes a
    // digest; only the compressions beyond the later ones' count as extra work. With no password or salt term the
    // expression is the one `pbkdf2WorkNsMax` evaluates, so the cap's boundary is exact.
    const size_t first_compressions = compressionsOf(hash, salt_bytes + 4);
    const size_t later_compressions = compressionsOf(hash, spec.digest_bytes);
    const size_t extra_compressions
        = first_compressions > later_compressions ? first_compressions - later_compressions : 0;
    return password_ns
        + blocksOf(hash, output_bytes)
        * (static_cast<double>(iterations) * hashCost(hash).hmac_block_ns
            + static_cast<double>(extra_compressions) * compression_ns);
}

double pbkdf2IterationsNs(WebCryptoHash hash, uint32_t iterations)
{
    return static_cast<double>(iterations) * hashCost(hash).hmac_block_ns;
}

double hkdfWorstCaseNs(WebCryptoHash hash, size_t key_bytes, size_t salt_bytes, size_t info_bytes, size_t output_bytes)
{
    const size_t digest_bytes = hashSpec(hash).digest_bytes;
    return digestWorstCaseNs(hash, key_bytes + salt_bytes)
        + blocksOf(hash, output_bytes)
        * (digestWorstCaseNs(hash, info_bytes + digest_bytes + 1) + hashCost(hash).hmac_block_ns);
}

double pbkdf2WorkNsMax() { return 1'000'000.0 * hashCost(WebCryptoHash::SHA256).hmac_block_ns; }

}
