// The job model behind every asynchronous SubtleCrypto method. A method validates its arguments on the VM thread,
// copies what the operation needs into native storage (secret bytes, `EVP_PKEY` references from `retainSharedPkey`,
// parameters), and wraps that work in a `CryptoJob` that owns the promise's deferred. `enqueueCryptoJobPromise` runs
// the job inline or hands it to the worker's crypto pool (`worker/js/crypto/jobs.zig`). `CryptoJob::run` is the only
// member that may execute on a pool thread, so the work it calls never touches a JSC object; the job builds JavaScript
// values only in `settle`, back on the VM thread. The job is destroyed on the VM thread too, because the deferred it
// owns holds `JSC::Strong` roots (`collo_crypto_job_destroy` in abi.h).

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/crypto/key_io/key_io.h"
#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/types.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <openssl/evp.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <memory>
#include <new>

namespace Collo::HostFunctions::WebCrypto {

using namespace Collo::JscSupport;

// Returns a plain `{ publicKey, privateKey }` object, the CryptoKeyPair dictionary generateKey resolves with.
JSC::JSObject* createCryptoKeyPairObject(JSC::JSGlobalObject*, JSC::VM&, JSColloCryptoKey*, JSColloCryptoKey*);

class CryptoJob {
public:
    // Takes ownership of `deferred`, which `settle` or the destructor releases. `vm` names the VM whose promise the
    // job settles; `collo_crypto_job_settle` refuses the job for any other VM.
    CryptoJob(ColloVm* vm, ColloPromiseDeferred* deferred, CryptoJobCost cost = CryptoJobCost::Heavy)
        : m_vm(vm)
        , m_deferred(deferred)
        , m_cost(cost)
    {
    }

    virtual ~CryptoJob()
    {
        if (m_deferred)
            collo_promise_deferred_release(m_deferred);
    }

    // Performs the operation. May run on a crypto pool thread, so it reads and writes only the job's native data.
    void run() { m_ok = runImpl(); }

    CryptoJobCost cost() const { return m_cost; }
    bool belongsTo(ColloVm* vm) const { return m_vm == vm; }

    // Settles the promise on the VM thread and releases the deferred; a second call returns
    // `COLLO_STATUS_INVALID_ARGUMENT`. The promise resolves with `resolveValue`'s result. It rejects with, in order of
    // precedence, a value passed to `rejectWithValue`, an exception thrown while building the result, or a DOMException
    // from `fail`'s code and message, which default to OperationError with no message. A non-OK status comes from
    // settling the promise itself, with any exception in `*out_exception`.
    ColloStatus settle(JSC::JSGlobalObject* global_object, ColloValue** out_exception)
    {
        if (!m_deferred)
            return COLLO_STATUS_INVALID_ARGUMENT;

        auto& vm = global_object->vm();
        JSC::JSLockHolder locker(vm);
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        JSC::JSValue value = m_ok ? resolveValue(global_object, scope) : JSC::JSValue();
        if (scope.exception()) {
            value = scope.exception()->value();
            scope.clearExceptionExceptTermination();
            m_ok = false;
        }
        if (m_rejection_value) {
            value = m_rejection_value;
            m_ok = false;
        }
        if (!value) {
            value = domExceptionValue(global_object, m_error_code, m_error_message);
            m_ok = false;
        }

        ColloStatus status = Collo::settlePromiseDeferred(m_vm, m_deferred, value, !m_ok, out_exception);
        collo_promise_deferred_release(m_deferred);
        m_deferred = nullptr;
        return status;
    }

protected:
    // Sets the DOMException a failed run rejects with. May run on a crypto pool thread inside `runImpl`, while the VM
    // thread later reads and destroys the message, so it is stored as an isolated copy: empty, or the sole reference
    // to a string that is not an atom. A shared reference would race on its refcount, and an atom string's destructor
    // removes it from the AtomStringTable of whichever thread frees it.
    void fail(DOMExceptionCode code = DOMExceptionCode::OperationError, WTF::String message = {})
    {
        m_error_code = code;
        m_error_message = WTF::move(message).isolatedCopy();
    }

    // Called only from `resolveValue`, on the VM thread. The value sits in heap memory the collector does not scan;
    // it stays alive because `settle` reads it back into a local before anything can allocate.
    void rejectWithValue(JSC::JSValue value) { m_rejection_value = value; }

private:
    virtual bool runImpl() = 0;
    virtual JSC::JSValue resolveValue(JSC::JSGlobalObject*, JSC::TopExceptionScope&) = 0;

    ColloVm* m_vm;
    // Holds the promise's resolving functions through `JSC::Strong` handles. No cell owns the job, so nothing these
    // roots keep alive can keep the job alive in turn. The job is destroyed on the VM thread once it settles, or when
    // its request ends and the pool discards it (`cancelForRequest` in `worker/js/crypto/jobs.zig`).
    ColloPromiseDeferred* m_deferred;
    CryptoJobCost m_cost { CryptoJobCost::Heavy };
    bool m_ok { false };
    DOMExceptionCode m_error_code { DOMExceptionCode::OperationError };
    WTF::String m_error_message;
    JSC::JSValue m_rejection_value;
};

// Runs `work(out)`, a callable `bool(WTF::Vector<uint8_t>&)` that fills `out` and returns false on failure, and
// resolves with a new ArrayBuffer holding a copy of the bytes. The bytes may be plaintext or key material, so the job
// zeroes them when it is destroyed.
template <typename Work> class BytesCryptoJob final : public CryptoJob {
public:
    BytesCryptoJob(ColloVm* vm, ColloPromiseDeferred* deferred, Work work, CryptoJobCost cost = CryptoJobCost::Heavy)
        : CryptoJob(vm, deferred, cost)
        , m_work(WTF::move(work))
    {
    }

    ~BytesCryptoJob() override
    {
        if (!m_bytes.isEmpty())
            WTF::secureZeroSpan(m_bytes.mutableSpan());
    }

private:
    bool runImpl() override { return m_work(m_bytes); }

    JSC::JSValue resolveValue(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope) override
    {
        JSC::JSValue error;
        auto result = createArrayBufferCopy(global_object, scope, m_bytes.span(), error);
        if (error) {
            rejectWithValue(error);
            return {};
        }
        return result;
    }

    Work m_work;
    WTF::Vector<uint8_t> m_bytes;
};

template <typename Work> BytesCryptoJob(ColloVm*, ColloPromiseDeferred*, Work, CryptoJobCost) -> BytesCryptoJob<Work>;
template <typename Work> BytesCryptoJob(ColloVm*, ColloPromiseDeferred*, Work) -> BytesCryptoJob<Work>;

// Runs `work(value)`, a callable `bool(bool&)` that stores the answer and returns false on failure, and resolves with
// that boolean. `verify` uses it, where an invalid signature is a false answer, not a failure.
template <typename Work> class BoolCryptoJob final : public CryptoJob {
public:
    BoolCryptoJob(ColloVm* vm, ColloPromiseDeferred* deferred, Work work, CryptoJobCost cost = CryptoJobCost::Heavy)
        : CryptoJob(vm, deferred, cost)
        , m_work(WTF::move(work))
    {
    }

private:
    bool runImpl() override { return m_work(m_value); }
    JSC::JSValue resolveValue(JSC::JSGlobalObject*, JSC::TopExceptionScope&) override
    {
        return JSC::jsBoolean(m_value);
    }

    Work m_work;
    bool m_value { false };
};

template <typename Work> BoolCryptoJob(ColloVm*, ColloPromiseDeferred*, Work, CryptoJobCost) -> BoolCryptoJob<Work>;
template <typename Work> BoolCryptoJob(ColloVm*, ColloPromiseDeferred*, Work) -> BoolCryptoJob<Work>;

// What a deriveKey job hands to `SecretKeyCryptoJob`: the derived material and the attributes of the key to create.
struct SecretKeyResult {
    CryptoKeyAlgorithm algorithm { CryptoKeyAlgorithm::Hmac };
    WebCryptoHash hash { WebCryptoHash::SHA256 };
    bool extractable { false };
    uint8_t usages { 0 };
    SecureBytes material;
};

// Runs `work(result)` and resolves with a new AES or HMAC CryptoKey built from it. Any other algorithm resolves to
// nothing, which rejects with OperationError.
template <typename Work> class SecretKeyCryptoJob final : public CryptoJob {
public:
    SecretKeyCryptoJob(
        ColloVm* vm, ColloPromiseDeferred* deferred, Work work, CryptoJobCost cost = CryptoJobCost::Heavy)
        : CryptoJob(vm, deferred, cost)
        , m_work(WTF::move(work))
    {
    }

private:
    bool runImpl() override { return m_work(m_result); }

    JSC::JSValue resolveValue(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope&) override
    {
        if (isAesAlgorithm(m_result.algorithm))
            return createAesKey(
                global_object, m_result.algorithm, m_result.material.release(), m_result.extractable, m_result.usages);
        if (m_result.algorithm == CryptoKeyAlgorithm::Hmac)
            return createHmacKey(
                global_object, m_result.hash, m_result.material.release(), m_result.extractable, m_result.usages);
        return {};
    }

    Work m_work;
    SecretKeyResult m_result;
};

template <typename Work>
SecretKeyCryptoJob(ColloVm*, ColloPromiseDeferred*, Work, CryptoJobCost) -> SecretKeyCryptoJob<Work>;
template <typename Work> SecretKeyCryptoJob(ColloVm*, ColloPromiseDeferred*, Work) -> SecretKeyCryptoJob<Work>;

// What a generateKey job hands to `KeyPairCryptoJob`: both halves of the pair and the usages each one gets.
struct KeyPairResult {
    CryptoKeyAlgorithm algorithm { CryptoKeyAlgorithm::RsaPss };
    WebCryptoHash hash { WebCryptoHash::SHA256 };
    CryptoKeyNamedCurve curve { CryptoKeyNamedCurve::None };
    bool extractable { false };
    uint8_t public_usages { 0 };
    uint8_t private_usages { 0 };
    bssl::UniquePtr<EVP_PKEY> public_key;
    bssl::UniquePtr<EVP_PKEY> private_key;
};

// Runs `work(result)` and resolves with a CryptoKeyPair. The public key is always extractable, as the Web Cryptography
// API's generate key operation of every asymmetric algorithm requires; `extractable` applies to the private key. A key
// its factory refuses (see `keys.h`) rejects with OperationError.
template <typename Work> class KeyPairCryptoJob final : public CryptoJob {
public:
    KeyPairCryptoJob(ColloVm* vm, ColloPromiseDeferred* deferred, Work work, CryptoJobCost cost = CryptoJobCost::Heavy)
        : CryptoJob(vm, deferred, cost)
        , m_work(WTF::move(work))
    {
    }

private:
    bool runImpl() override { return m_work(m_result); }

    JSC::JSValue resolveValue(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope) override
    {
        auto& vm = global_object->vm();
        JSColloCryptoKey* public_key = nullptr;
        JSColloCryptoKey* private_key = nullptr;
        if (isRsaAlgorithm(m_result.algorithm)) {
            public_key = createRsaKey(global_object, m_result.algorithm, m_result.hash, CryptoKeyType::Public,
                WTF::move(m_result.public_key), true, m_result.public_usages);
            if (scope.exception())
                return {};
            private_key = createRsaKey(global_object, m_result.algorithm, m_result.hash, CryptoKeyType::Private,
                WTF::move(m_result.private_key), m_result.extractable, m_result.private_usages);
        } else if (isEcAlgorithm(m_result.algorithm)) {
            public_key = createEcKey(global_object, m_result.algorithm, CryptoKeyType::Public, m_result.curve,
                WTF::move(m_result.public_key), true, m_result.public_usages);
            if (scope.exception())
                return {};
            private_key = createEcKey(global_object, m_result.algorithm, CryptoKeyType::Private, m_result.curve,
                WTF::move(m_result.private_key), m_result.extractable, m_result.private_usages);
        } else if (isOkpAlgorithm(m_result.algorithm)) {
            public_key = createOkpKey(global_object, m_result.algorithm, CryptoKeyType::Public,
                WTF::move(m_result.public_key), true, m_result.public_usages);
            if (scope.exception())
                return {};
            private_key = createOkpKey(global_object, m_result.algorithm, CryptoKeyType::Private,
                WTF::move(m_result.private_key), m_result.extractable, m_result.private_usages);
        }
        if (scope.exception() || !public_key || !private_key)
            return {};
        return createCryptoKeyPairObject(global_object, vm, public_key, private_key);
    }

    Work m_work;
    KeyPairResult m_result;
};

template <typename Work>
KeyPairCryptoJob(ColloVm*, ColloPromiseDeferred*, Work, CryptoJobCost) -> KeyPairCryptoJob<Work>;
template <typename Work> KeyPairCryptoJob(ColloVm*, ColloPromiseDeferred*, Work) -> KeyPairCryptoJob<Work>;

// Runs `work(decrypted)`, which decrypts the wrapped key on the pool, and imports the plaintext when the job settles
// on the VM thread: as `format`, with the attributes in `import_spec`, which the method normalized before queueing
// the job. An import failure rejects with its error. The decrypted bytes are zeroed when the job is destroyed.
template <typename Work> class UnwrapKeyCryptoJob final : public CryptoJob {
public:
    UnwrapKeyCryptoJob(ColloVm* owner, ColloPromiseDeferred* deferred, WTF::String format,
        UnwrappedKeyImportSpec import_spec, Work work, CryptoJobCost cost = CryptoJobCost::Heavy)
        : CryptoJob(owner, deferred, cost)
        // Everything the job carries onto the crypto pool is data it owns alone, so the format is an isolated copy
        // that shares no StringImpl with the VM thread's strings. Only `resolveValue` and the destructor touch it,
        // both on the VM thread.
        , m_format(WTF::move(format).isolatedCopy())
        , m_import_spec(import_spec)
        , m_work(WTF::move(work))
    {
    }

    ~UnwrapKeyCryptoJob() override
    {
        if (!m_decrypted.isEmpty())
            WTF::secureZeroSpan(m_decrypted.mutableSpan());
    }

private:
    bool runImpl() override { return m_work(m_decrypted); }

    JSC::JSValue resolveValue(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope) override
    {
        JSC::JSValue error;
        JSColloCryptoKey* key = nullptr;
        if (!importUnwrappedKeyBytesWithSpec(
                global_object, scope, m_format, WTF::move(m_decrypted), m_import_spec, key, error)) {
            if (error)
                rejectWithValue(error);
            return {};
        }
        return key;
    }

    WTF::String m_format;
    UnwrappedKeyImportSpec m_import_spec;
    Work m_work;
    WTF::Vector<uint8_t> m_decrypted;
};

template <typename Work>
UnwrapKeyCryptoJob(ColloVm*, ColloPromiseDeferred*, WTF::String, UnwrappedKeyImportSpec, Work, CryptoJobCost)
    -> UnwrapKeyCryptoJob<Work>;
template <typename Work>
UnwrapKeyCryptoJob(ColloVm*, ColloPromiseDeferred*, WTF::String, UnwrappedKeyImportSpec, Work)
    -> UnwrapKeyCryptoJob<Work>;

// The promise a SubtleCrypto method returns and the deferred that settles it. The deferred roots the promise's
// resolving functions, which keep `promise` alive until the deferred is released.
struct CryptoAsyncContext {
    ColloVm* owner { nullptr };
    JSC::JSValue promise;
    ColloPromiseDeferred* deferred { nullptr };
};

struct CryptoAsyncContextResult {
    CryptoAsyncContext value;
    JSC::EncodedJSValue error {};
    bool ok { false };
};

// Creates the method's promise. On success the caller owns `value.deferred` and hands it to the CryptoJob it builds.
// On failure `ok` is false and `error` is a rejected promise to return; an exception pending in `scope` becomes its
// reason and is cleared.
CryptoAsyncContextResult createCryptoAsyncContext(JSC::JSGlobalObject*, JSC::TopExceptionScope&);

// Consumes `job`, which owns `context.deferred`, and returns `context.promise` once the job has run inline and settled
// it or the crypto pool has accepted the job. Otherwise the job is destroyed, the context's promise is abandoned, and
// the call returns a new rejected promise: when `job` is null because its allocation failed, when no request turn is
// active, when the pool refuses the job, or when a job run inline fails to settle the promise. The worker accepts a
// job only for an active request or the boot context, since it discards a request's queued jobs when the request ends
// (`cancelForRequest` in `worker/js/crypto/jobs.zig`).
JSC::EncodedJSValue enqueueCryptoJobPromise(
    JSC::JSGlobalObject*, JSC::TopExceptionScope&, const CryptoAsyncContext&, std::unique_ptr<CryptoJob>);

} // namespace Collo::HostFunctions::WebCrypto
