// The `node:fs` binding: readFile, writeFile, mkdir, readdir, stat, unlink, rename and exists, each as a `*Sync`
// function and as a promise-returning one, gathered on the frozen global `__collo_node_fs` that module_loader.cpp's
// `node:fs` and `node:fs/promises` modules re-export. The functions without the suffix return promises, like their
// `fs.promises` twins, and take no callback. It runs on the VM thread of a worker, which installs it after its seccomp
// filter, and it is the one place the bridge performs file I/O.
//
// Every path is first routed through collo_worker_fs_route, and worker/fs/index.zig defines the namespaces it sorts
// paths into. A /tmp path reaches the real syscalls. A path in the read-only tree is answered from the index, and
// every mutation there fails with EROFS. Reading a file of the tree that is not yet copied into the tmpfs faults it
// in through worker/fs/fault.zig: a promise-returning read parks its promise, which settles on the event loop, and a
// synchronous read blocks the VM thread until the copy exists or the request's deadline passes. Every `*at` syscall
// here passes AT_FDCWD as its directory and only flags that the worker's seccomp filter admits
// (zygote/worker_boot/sandbox.zig), which fails any other directory or flag with EPERM. Every fd is opened
// close-on-exec and closed before the call that opened it returns.
//
// An errno failure throws or rejects with an Error carrying Node's `code`, `errno`, `syscall` and `path` properties,
// plus `dest` for rename. An argument of the wrong type or value fails with a TypeError carrying Node's
// ERR_INVALID_ARG_TYPE or ERR_INVALID_ARG_VALUE code.

#include "host_functions/node/fs.h"

#include "collo/abi.h"
#include "host_functions/runtime/bridge.h"
// For createBodyUint8ArrayCopy, which readFile shares with the fetch body readers.
#include "host_functions/server/fetch/body_utils.h"
#include "host_functions/support.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSNativeStdFunction.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/Vector.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <span>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

// Zig exports that abi.h does not declare: the routing calls of worker/fs/index.zig, which documents them and keeps the
// twin of every route constant below, and the fault entry points of worker/host/fs_fault.zig.
// FIXME: cpp.md allows extern "C" only on definitions of functions abi.h declares, so these belong in abi.h.
extern "C" {

// Laid out like RouteInfo in worker/fs/index.zig.
struct ColloWorkerFsRouteInfo {
    uint64_t size;
    uint64_t mtimeMs;
    uint32_t normalizedLen;
    uint32_t reserved;
};

int32_t collo_worker_fs_route(
    const char* path, size_t pathLen, char* outPath, size_t outPathCap, ColloWorkerFsRouteInfo* outInfo);

int32_t collo_worker_fs_readdir_next(const char* dir, size_t dirLen, uint64_t* cursor, char* outName, size_t outNameCap,
    uint32_t* outNameLen, uint8_t* outIsDir);

// The path of a file's copy in the tmpfs: the normalized path itself in a worker, but under another root in the
// in-process test install, which is why the read after an async fault asks instead of assuming. Returns the length
// written or a negative route error.
int32_t collo_worker_fs_materialized_path(const char* path, size_t pathLen, char* outPath, size_t outPathCap);

// Parks a promise-returning read of a file of the tree that is not yet in the tmpfs. Takes `deferred` on every path,
// including a non-zero return, and settles it on the worker's event loop.
int collo_runtime_fs_fault_read_file(void* runtime, uint64_t requestId, const char* path, size_t pathLen,
    ColloPromiseDeferred* deferred, uint64_t* outFaultId);

// Blocks the VM thread until the file is copied into the tmpfs or the request's deadline passes. Returns
// faultSyncStatusOk once the copy exists, faultSyncStatusNotFound when the file does not exist, and another value for
// any other failure.
int collo_runtime_fs_fault_sync(void* runtime, uint64_t requestId, const char* path, size_t pathLen);

// Records a direct read of an existing copy: it traces `worker.fs_fault.hit_local` and stamps the copy's last read,
// which keeps the idle sweep from evicting it (`recordLocalHit` in worker/fs/copies.zig).
void collo_runtime_fs_fault_hit_local(void* runtime, const char* path, size_t pathLen);

} // extern "C"

namespace {

// Copies of the route_class_* and route_error_* constants in worker/fs/index.zig.
constexpr int32_t routeClassTmp = 0;
constexpr int32_t routeClassDeployFile = 1;
constexpr int32_t routeClassDeployDir = 2;
constexpr int32_t routeClassNone = 3;
constexpr int32_t routeErrorTooLong = -1;
// `max_normalized_bytes` in worker/fs/index.zig, PATH_MAX with the NUL; collo_worker_fs_route refuses a smaller buffer.
constexpr size_t routePathCapacity = 4096;
// `path_bytes_max` in common/ipc/fs_index.zig plus one. A name arrives without a NUL, so the last byte is spare.
constexpr size_t routeNameCapacity = 1025;
// `readdir_cursor_start` in worker/fs/index.zig.
constexpr uint64_t readdirCursorStart = ~0ull;

constexpr size_t readChunkBytes = 16 * 1024;
// The largest file of the read-only tree a read accepts: abi.h's copy of `max_fault_file_bytes` in
// common/limits/fs_fault.zig, which says why it equals the default tmpfs size. Below it, the copy budget in
// worker/fs/copies.zig applies. A /tmp read and a /tmp listing have no cap of their own: the worker's tmpfs bounds what
// they can find, and the memory they allocate is charged to the worker's cgroup.
constexpr size_t maxReadFileBytes = COLLO_FS_FAULT_MAX_FILE_BYTES;
constexpr size_t getdentsBufferBytes = 16 * 1024;
constexpr unsigned fsPropertyAttributes = static_cast<unsigned>(JSC::PropertyAttribute::DontEnum);

struct FsResult {
    JSC::JSValue value { JSC::jsUndefined() };
    JSC::JSValue error { JSC::jsUndefined() };
    bool ok { false };
    // `value` is already the promise of a parked fault, which encodePromiseResult returns as is. Only the
    // promise-returning readFile sets it, so encodeSyncResult never sees it.
    bool pending { false };
};

// The kernel's struct linux_dirent64, the record getdents64 fills its buffer with.
struct LinuxDirent64 {
    uint64_t inode;
    int64_t offset;
    unsigned short reclen;
    unsigned char type;
    char name[];
};

WTF::String stringFromUtf8Bytes(std::span<const uint8_t> bytes)
{
    return WTF::String::fromUTF8ReplacingInvalidSequences(
        std::span<const char8_t> { reinterpret_cast<const char8_t*>(bytes.data()), bytes.size() });
}

WTF::String stringFromCString(const char* value)
{
    return WTF::String::fromUTF8ReplacingInvalidSequences(
        std::span<const char8_t> { reinterpret_cast<const char8_t*>(value), std::strlen(value) });
}

// An errno without a case here reports the code EIO, while the error's `errno` and message keep the real value.
WTF::ASCIILiteral errnoCode(int err)
{
    switch (err) {
    case EACCES:
        return "EACCES"_s;
    case EEXIST:
        return "EEXIST"_s;
    case EFBIG:
        return "EFBIG"_s;
    case EINVAL:
        return "EINVAL"_s;
    case EIO:
        return "EIO"_s;
    case EISDIR:
        return "EISDIR"_s;
    case ENAMETOOLONG:
        return "ENAMETOOLONG"_s;
    case ENOENT:
        return "ENOENT"_s;
    case ENOMEM:
        return "ENOMEM"_s;
    case ENOSPC:
        return "ENOSPC"_s;
    case ENOTDIR:
        return "ENOTDIR"_s;
    case EPERM:
        return "EPERM"_s;
    case EROFS:
        return "EROFS"_s;
    default:
        return "EIO"_s;
    }
}

// The Error of every errno failure: the message "<syscall> '<path>' failed: <detail>" and non-enumerable `code`,
// `errno` (negative, as Node reports it), `syscall` and `path` properties. `detail` is strerror's text for a real
// errno and the fault's reason for a failed fault.
JSC::JSObject* createFsErrorWithDetail(JSC::JSGlobalObject* globalObject, JSC::VM& vm, int err,
    WTF::ASCIILiteral syscallName, const WTF::CString& path, const WTF::String& detail)
{
    WTF::String pathString = stringFromUtf8Bytes(
        std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(path.data()), path.length() });
    auto* error
        = JSC::createError(globalObject, WTF::makeString(syscallName, " '"_s, pathString, "' failed: "_s, detail));
    error->putDirect(vm, JSC::Identifier::fromString(vm, "code"_s), JSC::jsString(vm, WTF::String(errnoCode(err))),
        fsPropertyAttributes);
    error->putDirect(vm, JSC::Identifier::fromString(vm, "errno"_s), JSC::jsNumber(-err), fsPropertyAttributes);
    error->putDirect(vm, JSC::Identifier::fromString(vm, "syscall"_s), JSC::jsString(vm, WTF::String(syscallName)),
        fsPropertyAttributes);
    error->putDirect(
        vm, JSC::Identifier::fromString(vm, "path"_s), JSC::jsString(vm, pathString), fsPropertyAttributes);
    return error;
}

JSC::JSObject* createFsError(
    JSC::JSGlobalObject* globalObject, JSC::VM& vm, int err, WTF::ASCIILiteral syscallName, const WTF::CString& path)
{
    return createFsErrorWithDetail(globalObject, vm, err, syscallName, path, stringFromCString(std::strerror(err)));
}

// A TypeError for a misused argument, carrying the `code` Node gives the same misuse.
JSC::JSObject* createTypeErrorWithCode(
    JSC::JSGlobalObject* globalObject, JSC::VM& vm, WTF::ASCIILiteral code, const WTF::String& message)
{
    auto* error = JSC::createTypeError(globalObject, message);
    error->putDirect(
        vm, JSC::Identifier::fromString(vm, "code"_s), JSC::jsString(vm, WTF::String(code)), fsPropertyAttributes);
    return error;
}

// A rename's errno failure, which also carries the destination as `dest`.
JSC::JSObject* createFsErrorWithDest(JSC::JSGlobalObject* globalObject, JSC::VM& vm, int err,
    WTF::ASCIILiteral syscallName, const WTF::CString& path, const WTF::CString& dest)
{
    auto* error = createFsError(globalObject, vm, err, syscallName, path);
    error->putDirect(vm, JSC::Identifier::fromString(vm, "dest"_s),
        JSC::jsString(vm,
            stringFromUtf8Bytes(
                std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(dest.data()), dest.length() })),
        fsPropertyAttributes);
    return error;
}

FsResult ok(JSC::JSValue value) { return { value, JSC::jsUndefined(), true }; }

FsResult fail(JSC::JSValue error) { return { JSC::jsUndefined(), error, false }; }

struct RoutedPath {
    int32_t klass { routeClassNone };
    uint64_t size { 0 };
    uint64_t mtimeMs { 0 };
    uint32_t normalizedLen { 0 };
    // The normalized absolute path with a trailing NUL, which the syscalls receive as is: inside a worker, lexical
    // resolution names the file the kernel would (`normalizePath` in worker/fs/index.zig says why).
    char normalized[routePathCapacity];
};

bool routeFsPath(JSC::JSGlobalObject* globalObject, JSC::VM& vm, const WTF::CString& path,
    WTF::ASCIILiteral syscallName, RoutedPath& out, JSC::JSValue& outError)
{
    ColloWorkerFsRouteInfo info {};
    int32_t klass = collo_worker_fs_route(path.data(), path.length(), out.normalized, sizeof(out.normalized), &info);
    if (klass == routeErrorTooLong) {
        outError = createFsError(globalObject, vm, ENAMETOOLONG, syscallName, path);
        return false;
    }
    if (klass < 0) {
        // Any other negative value means no installed index or a misused call, a worker bug rather than anything the
        // caller did, so the operation fails with EIO.
        outError = createFsError(globalObject, vm, EIO, syscallName, path);
        return false;
    }
    out.klass = klass;
    out.size = info.size;
    out.mtimeMs = info.mtimeMs;
    out.normalizedLen = info.normalizedLen;
    return true;
}

double mtimeMsFromTimespec(const struct timespec& ts)
{
    return static_cast<double>(ts.tv_sec) * 1000.0 + static_cast<double>(ts.tv_nsec) / 1e6;
}

JSC::JSObject* makeStatObject(
    JSC::JSGlobalObject* globalObject, JSC::VM& vm, uint64_t size, mode_t mode, double mtimeMs)
{
    auto* object = JSC::constructEmptyObject(globalObject);
    object->putDirect(vm, JSC::Identifier::fromString(vm, "size"_s), JSC::jsNumber(static_cast<double>(size)));
    object->putDirect(vm, JSC::Identifier::fromString(vm, "mode"_s), JSC::jsNumber(mode));
    object->putDirect(vm, JSC::Identifier::fromString(vm, "mtimeMs"_s), JSC::jsNumber(mtimeMs));
    object->putDirect(vm, JSC::Identifier::fromString(vm, "isFile"_s), JSC::jsBoolean(S_ISREG(mode)));
    object->putDirect(vm, JSC::Identifier::fromString(vm, "isDirectory"_s), JSC::jsBoolean(S_ISDIR(mode)));
    return object;
}

bool pathArgument(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, JSC::CallFrame* callFrame, unsigned index,
    WTF::CString& out, JSC::JSValue& outError)
{
    JSC::VM& vm = globalObject->vm();
    if (callFrame->argumentCount() <= index || callFrame->argument(index).isUndefined()) {
        outError
            = createTypeErrorWithCode(globalObject, vm, "ERR_INVALID_ARG_TYPE"_s, "fs path argument is required."_s);
        return false;
    }

    // Only a string is a path, and the type is checked before any conversion, so a number or an object never becomes
    // a lookup of its string form and a Symbol fails with a coded TypeError. Node also accepts a Buffer or URL path;
    // here both fail with ERR_INVALID_ARG_TYPE.
    JSC::JSValue pathValue = callFrame->argument(index);
    if (!pathValue.isString()) {
        outError = createTypeErrorWithCode(globalObject, vm, "ERR_INVALID_ARG_TYPE"_s, "fs path must be a string."_s);
        return false;
    }

    WTF::String path = pathValue.toWTFString(globalObject);
    if (scope.exception()) {
        outError = scope.exception()->value();
        (void)scope.tryClearException();
        return false;
    }

    for (unsigned i = 0; i < path.length(); ++i) {
        if (path[i] != 0)
            continue;
        outError = createTypeErrorWithCode(
            globalObject, vm, "ERR_INVALID_ARG_VALUE"_s, "fs path must not contain NUL bytes."_s);
        return false;
    }

    out = path.utf8();
    if (!out.data()) {
        outError = JSC::createOutOfMemoryError(globalObject);
        return false;
    }
    if (out.length() == 0) {
        outError = createFsError(globalObject, vm, ENOENT, "openat"_s, out);
        return false;
    }
    return true;
}

// writeFile's data: a string, written as UTF-8, or a Uint8Array, written byte for byte, so the bytes readFile returns
// without an encoding write back unchanged. `bytes` points into the argument's buffer, which the call frame keeps
// alive, and no JavaScript runs before the write finishes, so nothing can detach or shrink the buffer meanwhile.
struct WriteData {
    WTF::CString string;
    std::span<const uint8_t> bytes;
    bool isBytes { false };

    std::span<const uint8_t> span() const
    {
        if (isBytes)
            return bytes;
        return { reinterpret_cast<const uint8_t*>(string.data()), string.length() };
    }
};

bool writeDataArgument(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, JSC::CallFrame* callFrame,
    unsigned index, WriteData& out, JSC::JSValue& outError)
{
    JSC::VM& vm = globalObject->vm();
    if (callFrame->argumentCount() <= index || callFrame->argument(index).isUndefined()) {
        outError
            = createTypeErrorWithCode(globalObject, vm, "ERR_INVALID_ARG_TYPE"_s, "fs data argument is required."_s);
        return false;
    }

    JSC::JSValue value = callFrame->argument(index);
    if (auto* array = dynamicDowncast<JSC::JSUint8Array>(value)) {
        if (array->isDetached() || array->isOutOfBounds()) {
            outError = createTypeErrorWithCode(
                globalObject, vm, "ERR_INVALID_ARG_VALUE"_s, "fs data Uint8Array is detached."_s);
            return false;
        }
        out.bytes = { static_cast<const uint8_t*>(array->vector()), array->byteLength() };
        out.isBytes = true;
        return true;
    }

    // Any other value fails with ERR_INVALID_ARG_TYPE before conversion rather than being written as its string form.
    if (!value.isString()) {
        outError = createTypeErrorWithCode(
            globalObject, vm, "ERR_INVALID_ARG_TYPE"_s, "fs data must be a string or a Uint8Array."_s);
        return false;
    }

    WTF::String stringValue = value.toWTFString(globalObject);
    if (scope.exception()) {
        outError = scope.exception()->value();
        (void)scope.tryClearException();
        return false;
    }
    out.string = stringValue.utf8();
    out.isBytes = false;
    if (!out.string.data()) {
        outError = JSC::createOutOfMemoryError(globalObject);
        return false;
    }
    return true;
}

// What readFile returns. Without an encoding it is a Uint8Array of the exact bytes, since the runtime has no Buffer
// and TextDecoder covers text. The encoding "utf8" or "utf-8", given as a string or as `options.encoding`, returns a
// string with invalid sequences replaced. Every other Node encoding fails with ERR_INVALID_ARG_VALUE rather than being
// re-encoded, because TextDecoder and TextEncoder already cover transcoding.
enum class ReadOutput : uint8_t {
    bytes,
    utf8,
};

bool parseReadEncoding(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, JSC::CallFrame* callFrame,
    unsigned index, ReadOutput& out, JSC::JSValue& outError)
{
    JSC::VM& vm = globalObject->vm();
    out = ReadOutput::bytes;
    if (callFrame->argumentCount() <= index)
        return true;
    JSC::JSValue value = callFrame->argument(index);
    if (value.isUndefinedOrNull())
        return true;

    JSC::JSValue encodingValue = value;
    if (!value.isString()) {
        if (!value.isObject()) {
            outError = createTypeErrorWithCode(globalObject, vm, "ERR_INVALID_ARG_TYPE"_s,
                "fs readFile options must be an encoding string or an options object."_s);
            return false;
        }
        encodingValue = value.getObject()->get(globalObject, JSC::Identifier::fromString(vm, "encoding"_s));
        if (scope.exception()) {
            outError = scope.exception()->value();
            (void)scope.tryClearException();
            return false;
        }
        if (encodingValue.isUndefinedOrNull())
            return true;
        if (!encodingValue.isString()) {
            outError = createTypeErrorWithCode(
                globalObject, vm, "ERR_INVALID_ARG_TYPE"_s, "fs readFile options.encoding must be a string."_s);
            return false;
        }
    }

    WTF::String name = encodingValue.toWTFString(globalObject);
    if (scope.exception()) {
        outError = scope.exception()->value();
        (void)scope.tryClearException();
        return false;
    }
    if (equalIgnoringASCIICase(name, "utf8"_s) || equalIgnoringASCIICase(name, "utf-8"_s)) {
        out = ReadOutput::utf8;
        return true;
    }
    outError = createTypeErrorWithCode(globalObject, vm, "ERR_INVALID_ARG_VALUE"_s,
        WTF::makeString("The argument 'encoding' is invalid: "_s, name, ". Only \"utf8\" is supported."_s));
    return false;
}

// Every readFile path builds its result here: a /tmp file, a copy read directly, and a copy read after a sync or an
// async fault. All of them therefore apply the encoding the same way.
FsResult encodeReadData(
    JSC::JSGlobalObject* globalObject, JSC::VM& vm, std::span<const uint8_t> bytes, ReadOutput output)
{
    if (output == ReadOutput::utf8)
        return ok(JSC::jsString(vm, stringFromUtf8Bytes(bytes)));
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* array = Collo::HostFunctions::createBodyUint8ArrayCopy(globalObject, scope, bytes);
    if (scope.exception()) {
        JSC::JSValue error = scope.exception()->value();
        (void)scope.tryClearException();
        return fail(error);
    }
    if (!array)
        return fail(JSC::createOutOfMemoryError(globalObject));
    return ok(array);
}

// AT_FDCWD is a kernel `int`. Passed to the variadic syscall() as an int, it would reach the argument register through
// a 32-bit move that zeroes the high word. The worker's seccomp filter compares only the low word, as the kernel reads
// it (appendAtFdcwdPolicy in zygote/worker_boot/sandbox.zig), so both forms pass; the sign-extended long keeps the
// whole register canonical and matches what Zig's `*at` wrappers pass.
static constexpr long kAtFdcwd = AT_FDCWD;

int sysOpenAt(const char* path, int flags, mode_t mode)
{
    for (;;) {
        int fd = static_cast<int>(syscall(SYS_openat, kAtFdcwd, path, flags, mode));
        if (fd >= 0)
            return fd;
        if (errno != EINTR)
            return -1;
    }
}

int sysNewFstatAt(const char* path, struct stat* statBuffer)
{
    for (;;) {
        int rc = static_cast<int>(syscall(SYS_newfstatat, kAtFdcwd, path, statBuffer, 0));
        if (rc == 0)
            return 0;
        if (errno != EINTR)
            return -1;
    }
}

int sysMkdirAt(const char* path, mode_t mode)
{
    for (;;) {
        int rc = static_cast<int>(syscall(SYS_mkdirat, kAtFdcwd, path, mode));
        if (rc == 0)
            return 0;
        if (errno != EINTR)
            return -1;
    }
}

int sysUnlinkAt(const char* path)
{
    for (;;) {
        int rc = static_cast<int>(syscall(SYS_unlinkat, kAtFdcwd, path, 0));
        if (rc == 0)
            return 0;
        if (errno != EINTR)
            return -1;
    }
}

int sysRenameAt2(const char* oldPath, const char* newPath)
{
    for (;;) {
        int rc = static_cast<int>(syscall(SYS_renameat2, kAtFdcwd, oldPath, kAtFdcwd, newPath, 0));
        if (rc == 0)
            return 0;
        if (errno != EINTR)
            return -1;
    }
}

int sysFtruncate(int fd, off_t size)
{
    for (;;) {
        int rc = static_cast<int>(syscall(SYS_ftruncate, fd, size));
        if (rc == 0)
            return 0;
        if (errno != EINTR)
            return -1;
    }
}

void closeBestEffort(int fd)
{
    if (fd >= 0)
        close(fd);
}

bool writeAll(int fd, const char* data, size_t size, int& outErrno)
{
    size_t written = 0;
    while (written < size) {
        ssize_t rc = write(fd, data + written, size - written);
        if (rc > 0) {
            written += static_cast<size_t>(rc);
            continue;
        }
        if (rc < 0 && errno == EINTR)
            continue;
        outErrno = rc < 0 ? errno : EIO;
        return false;
    }
    return true;
}

FsResult statOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::CString path;
    JSC::JSValue error;
    if (!pathArgument(globalObject, scope, callFrame, 0, path, error))
        return fail(error);

    RoutedPath routed;
    if (!routeFsPath(globalObject, vm, path, "stat"_s, routed, error))
        return fail(error);

    if (routed.klass == routeClassTmp) {
        struct stat statBuffer;
        if (sysNewFstatAt(routed.normalized, &statBuffer) != 0)
            return fail(createFsError(globalObject, vm, errno, "stat"_s, path));
        return ok(makeStatObject(globalObject, vm, static_cast<uint64_t>(statBuffer.st_size), statBuffer.st_mode,
            mtimeMsFromTimespec(statBuffer.st_mtim)));
    }
    // A path in the tree is answered from the index: a file reports its size, both kinds report the index's
    // `deploy_epoch_ms` as mtime, and the modes are read-only.
    if (routed.klass == routeClassDeployFile)
        return ok(makeStatObject(globalObject, vm, routed.size, S_IFREG | 0444, static_cast<double>(routed.mtimeMs)));
    if (routed.klass == routeClassDeployDir)
        return ok(makeStatObject(globalObject, vm, 0, S_IFDIR | 0555, static_cast<double>(routed.mtimeMs)));
    return fail(createFsError(globalObject, vm, ENOENT, "stat"_s, path));
}

FsResult existsOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::CString path;
    JSC::JSValue error;
    if (!pathArgument(globalObject, scope, callFrame, 0, path, error))
        return fail(error);

    // A routing failure, such as a path too long or no installed index, answers false instead of throwing.
    RoutedPath routed;
    ColloWorkerFsRouteInfo info {};
    int32_t klass
        = collo_worker_fs_route(path.data(), path.length(), routed.normalized, sizeof(routed.normalized), &info);
    if (klass < 0)
        return ok(JSC::jsBoolean(false));
    if (klass == routeClassDeployFile || klass == routeClassDeployDir)
        return ok(JSC::jsBoolean(true));
    if (klass == routeClassNone)
        return ok(JSC::jsBoolean(false));

    struct stat statBuffer;
    if (sysNewFstatAt(routed.normalized, &statBuffer) == 0)
        return ok(JSC::jsBoolean(true));
    if (errno == ENOENT || errno == ENOTDIR)
        return ok(JSC::jsBoolean(false));
    return fail(createFsError(globalObject, vm, errno, "stat"_s, path));
}

// Reads a copy in the tmpfs into one allocation of the size fstat reports. The allocation is charged to the worker's
// cgroup, so failing it is an ordinary outcome that becomes an OutOfMemoryError. Takes `fd` and closes it on every
// path; a read that ends before that size fails with EIO.
FsResult readDeployFileExact(
    JSC::JSGlobalObject* globalObject, JSC::VM& vm, const WTF::CString& path, int fd, ReadOutput output)
{
    struct stat statBuffer;
    if (fstat(fd, &statBuffer) != 0) {
        int savedErrno = errno;
        closeBestEffort(fd);
        return fail(createFsError(globalObject, vm, savedErrno, "fstat"_s, path));
    }
    if (S_ISDIR(statBuffer.st_mode)) {
        closeBestEffort(fd);
        return fail(createFsError(globalObject, vm, EISDIR, "read"_s, path));
    }
    // worker/fs/fault.zig never copies a file above maxReadFileBytes, so a larger copy cannot exist; the check keeps
    // the allocation below bounded by this file's own constant and answers EFBIG.
    if (statBuffer.st_size < 0 || statBuffer.st_size > static_cast<off_t>(maxReadFileBytes)) {
        closeBestEffort(fd);
        return fail(createFsError(globalObject, vm, EFBIG, "read"_s, path));
    }

    const size_t size = static_cast<size_t>(statBuffer.st_size);
    WTF::Vector<uint8_t> bytes;
    if (!bytes.tryGrow(size)) {
        closeBestEffort(fd);
        return fail(JSC::createOutOfMemoryError(globalObject));
    }
    size_t readTotal = 0;
    while (readTotal < size) {
        ssize_t rc = read(fd, bytes.mutableSpan().data() + readTotal, size - readTotal);
        if (rc > 0) {
            readTotal += static_cast<size_t>(rc);
            continue;
        }
        if (rc < 0 && errno == EINTR)
            continue;
        int savedErrno = rc < 0 ? errno : EIO;
        closeBestEffort(fd);
        return fail(createFsError(globalObject, vm, savedErrno, "read"_s, path));
    }
    closeBestEffort(fd);
    return encodeReadData(globalObject, vm, bytes.span(), output);
}

// Faults a file of the tree in for a promise-returning read and returns, marked pending, a promise for its contents
// in the form `output` selects. Without a host runtime or an execution context nothing can fault the file in, so the
// read fails with ENOENT as for a path outside the tree. A fault that cannot be scheduled fails with EIO at once
// (`schedule` in worker/fs/fault.zig lists why it can fail), so the caller never waits on a promise nothing settles.
FsResult scheduleDeployReadFault(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, const WTF::CString& path,
    const RoutedPath& routed, ReadOutput output)
{
    JSC::VM& vm = globalObject->vm();
    Collo::HostFunctions::Runtime::ActiveRequestRuntime runtime;
    if (!Collo::HostFunctions::Runtime::optionalActiveRequestRuntime(globalObject, runtime)) {
        return fail(createFsError(globalObject, vm, ENOENT, "openat"_s, path));
    }

    auto deferred_promise = Collo::HostFunctions::Runtime::createPromiseDeferred(
        globalObject, scope, *runtime.owner, "Failed to create fs read promise."_s);
    if (!deferred_promise.ok) {
        JSC::JSValue error = JSC::jsUndefined();
        if (scope.exception()) {
            error = scope.exception()->value();
            (void)scope.tryClearException();
        } else
            error = createFsError(globalObject, vm, EIO, "openat"_s, path);
        return fail(error);
    }

    uint64_t fault_id = 0;
    int status = collo_runtime_fs_fault_read_file(runtime.host_runtime, runtime.exec_ctx->request_id, routed.normalized,
        routed.normalizedLen, deferred_promise.value.deferred, &fault_id);
    if (status != 0) {
        // Zig took the deferred although the call failed and released it unsettled, so nothing references the
        // promise any more and the collector reclaims it.
        return fail(createFsError(globalObject, vm, EIO, "openat"_s, path));
    }

    auto* pending = dynamicDowncast<JSC::JSPromise>(deferred_promise.value.promise);
    if (!pending)
        return fail(createFsError(globalObject, vm, EIO, "openat"_s, path));

    // The fault resolves its promise with undefined once the copy exists (`resolveWaiters` in
    // worker/fs/fault_completion.zig). The value the caller sees comes from the reaction chained below, which reads the
    // copy and applies the encoding the same way a synchronous read does.
    WTF::CString normalizedCopy(std::span<const char> { routed.normalized, routed.normalizedLen });
    auto* settled = JSC::JSNativeStdFunction::create(vm, globalObject, 1, "fsFaultSettleRead"_s,
        [path, normalizedCopy, output](JSC::JSGlobalObject* lambdaGlobal, JSC::CallFrame*) -> JSC::EncodedJSValue {
            JSC::VM& lambdaVm = lambdaGlobal->vm();
            auto lambdaScope = DECLARE_THROW_SCOPE(lambdaVm);
            // The copy may live outside the normalized path, as collo_worker_fs_materialized_path explains.
            char physical[routePathCapacity];
            int32_t physicalLen = collo_worker_fs_materialized_path(
                normalizedCopy.data(), normalizedCopy.length(), physical, sizeof(physical));
            if (physicalLen < 0) {
                return JSC::JSValue::encode(JSC::throwException(
                    lambdaGlobal, lambdaScope, createFsError(lambdaGlobal, lambdaVm, EIO, "read"_s, path)));
            }
            // This read records no local hit, so `worker.fs_fault.hit_local` traces only reads of a copy that existed
            // before the call; copying the file already stamped its last read in the ledger.
            int deployFd = sysOpenAt(physical, O_RDONLY | O_CLOEXEC, 0);
            if (deployFd < 0) {
                return JSC::JSValue::encode(JSC::throwException(
                    lambdaGlobal, lambdaScope, createFsError(lambdaGlobal, lambdaVm, errno, "openat"_s, path)));
            }
            FsResult readResult = readDeployFileExact(lambdaGlobal, lambdaVm, path, deployFd, output);
            if (!readResult.ok) {
                return JSC::JSValue::encode(JSC::throwException(lambdaGlobal, lambdaScope, readResult.error));
            }
            return JSC::JSValue::encode(readResult.value);
        });
    auto* faulted = JSC::JSNativeStdFunction::create(vm, globalObject, 1, "fsFaultSettleReject"_s,
        [path](JSC::JSGlobalObject* lambdaGlobal, JSC::CallFrame* lambdaFrame) -> JSC::EncodedJSValue {
            JSC::VM& lambdaVm = lambdaGlobal->vm();
            auto lambdaScope = DECLARE_THROW_SCOPE(lambdaVm);
            // The fault rejects with a reason string from worker/fs/fault_completion.zig, which becomes the detail of
            // an EIO error: the index already decided before the fault that the path exists.
            // FIXME: a not_found answer from the host also becomes EIO here, while syncDeployReadFault turns it into
            // ENOENT.
            WTF::String reason = lambdaFrame->argument(0).toWTFString(lambdaGlobal);
            if (lambdaScope.exception()) {
                (void)lambdaScope.tryClearException();
                reason = "fs fault failed"_s;
            }
            return JSC::JSValue::encode(JSC::throwException(lambdaGlobal, lambdaScope,
                createFsErrorWithDetail(lambdaGlobal, lambdaVm, EIO, "read"_s, path, reason)));
        });
    auto* chained = JSC::JSPromise::create(vm, globalObject->promiseStructure());
    pending->performPromiseThen(vm, globalObject, settled, faulted, chained);

    FsResult result = ok(chained);
    result.pending = true;
    return result;
}

constexpr int faultSyncStatusOk = 0;
constexpr int faultSyncStatusNotFound = 3;

// Faults a file of the tree in for a synchronous read, blocking the VM thread until the copy exists or the request's
// deadline passes, then reads the copy at the normalized path, where a worker keeps it. `faultSync` in
// worker/fs/fault_sync.zig owns the wait and explains why a timeout cannot outlast the request. A file the host does
// not have fails with ENOENT, as does a call with no host runtime or execution context; any other fault failure fails
// with EIO.
FsResult syncDeployReadFault(JSC::JSGlobalObject* globalObject, JSC::VM& vm, const WTF::CString& path,
    const RoutedPath& routed, ReadOutput output)
{
    Collo::HostFunctions::Runtime::ActiveRequestRuntime runtime;
    if (!Collo::HostFunctions::Runtime::optionalActiveRequestRuntime(globalObject, runtime)) {
        return fail(createFsError(globalObject, vm, ENOENT, "openat"_s, path));
    }

    int status = collo_runtime_fs_fault_sync(
        runtime.host_runtime, runtime.exec_ctx->request_id, routed.normalized, routed.normalizedLen);
    if (status == faultSyncStatusNotFound)
        return fail(createFsError(globalObject, vm, ENOENT, "openat"_s, path));
    if (status != faultSyncStatusOk)
        return fail(createFsError(globalObject, vm, EIO, "openat"_s, path));

    // No local hit is recorded, for the reason given in scheduleDeployReadFault.
    // FIXME: this open and the direct one in readFileOperation use the normalized path instead of asking
    // collo_worker_fs_materialized_path, so under the in-process test install they miss the copy.
    int deployFd = sysOpenAt(routed.normalized, O_RDONLY | O_CLOEXEC, 0);
    if (deployFd < 0)
        return fail(createFsError(globalObject, vm, errno, "openat"_s, path));
    return readDeployFileExact(globalObject, vm, path, deployFd, output);
}

FsResult readFileOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame, bool allowAsyncFault)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::CString path;
    JSC::JSValue error;
    if (!pathArgument(globalObject, scope, callFrame, 0, path, error))
        return fail(error);

    ReadOutput output = ReadOutput::bytes;
    if (!parseReadEncoding(globalObject, scope, callFrame, 1, output, error))
        return fail(error);

    RoutedPath routed;
    if (!routeFsPath(globalObject, vm, path, "openat"_s, routed, error))
        return fail(error);
    if (routed.klass == routeClassDeployFile) {
        // A copy already in the tmpfs is read directly, and the read is recorded as a local hit.
        int deployFd = sysOpenAt(routed.normalized, O_RDONLY | O_CLOEXEC, 0);
        if (deployFd >= 0) {
            auto* collo_global = dynamicDowncast<Collo::GlobalObject>(globalObject);
            if (collo_global) {
                void* host_runtime = Collo::HostFunctions::Runtime::hostRuntime(collo_global->owner());
                if (host_runtime)
                    collo_runtime_fs_fault_hit_local(host_runtime, routed.normalized, routed.normalizedLen);
            }
            return readDeployFileExact(globalObject, vm, path, deployFd, output);
        }
        if (errno != ENOENT)
            return fail(createFsError(globalObject, vm, errno, "openat"_s, path));
        // No copy yet. The index knows the size, so a file above maxReadFileBytes fails here with the EFBIG that
        // readDeployFileExact gives; the fault would refuse the file too, but as EIO.
        if (routed.size > maxReadFileBytes)
            return fail(createFsError(globalObject, vm, EFBIG, "read"_s, path));
        if (allowAsyncFault)
            return scheduleDeployReadFault(globalObject, scope, path, routed, output);
        return syncDeployReadFault(globalObject, vm, path, routed, output);
    }
    if (routed.klass == routeClassDeployDir)
        return fail(createFsError(globalObject, vm, EISDIR, "read"_s, path));
    if (routed.klass == routeClassNone)
        return fail(createFsError(globalObject, vm, ENOENT, "openat"_s, path));

    int fd = sysOpenAt(routed.normalized, O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0)
        return fail(createFsError(globalObject, vm, errno, "openat"_s, path));

    struct stat statBuffer;
    if (fstat(fd, &statBuffer) != 0) {
        int savedErrno = errno;
        closeBestEffort(fd);
        return fail(createFsError(globalObject, vm, savedErrno, "fstat"_s, path));
    }
    if (S_ISDIR(statBuffer.st_mode)) {
        closeBestEffort(fd);
        return fail(createFsError(globalObject, vm, EISDIR, "read"_s, path));
    }
    // A /tmp file has no size cap here, for the reason given at maxReadFileBytes; a failed allocation becomes an
    // OutOfMemoryError.
    WTF::Vector<uint8_t> bytes;
    uint8_t chunk[readChunkBytes];
    for (;;) {
        ssize_t rc = read(fd, chunk, sizeof(chunk));
        if (rc > 0) {
            if (!bytes.tryAppend(std::span<const uint8_t> { chunk, static_cast<size_t>(rc) })) {
                closeBestEffort(fd);
                return fail(JSC::createOutOfMemoryError(globalObject));
            }
            continue;
        }
        if (rc == 0)
            break;
        if (errno == EINTR)
            continue;
        int savedErrno = errno;
        closeBestEffort(fd);
        return fail(createFsError(globalObject, vm, savedErrno, "read"_s, path));
    }

    closeBestEffort(fd);
    return encodeReadData(globalObject, vm, bytes.span(), output);
}

FsResult writeFileOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::CString path;
    JSC::JSValue error;
    if (!pathArgument(globalObject, scope, callFrame, 0, path, error))
        return fail(error);

    WriteData data;
    if (!writeDataArgument(globalObject, scope, callFrame, 1, data, error))
        return fail(error);

    RoutedPath routed;
    if (!routeFsPath(globalObject, vm, path, "openat"_s, routed, error))
        return fail(error);
    // Only /tmp is writable: any other path fails with EROFS, whether or not the index lists it.
    if (routed.klass != routeClassTmp)
        return fail(createFsError(globalObject, vm, EROFS, "openat"_s, path));

    int fd = sysOpenAt(routed.normalized, O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0)
        return fail(createFsError(globalObject, vm, errno, "openat"_s, path));
    if (sysFtruncate(fd, 0) != 0) {
        int savedErrno = errno;
        closeBestEffort(fd);
        return fail(createFsError(globalObject, vm, savedErrno, "ftruncate"_s, path));
    }

    const std::span<const uint8_t> payload = data.span();
    int writeErrno = 0;
    if (!writeAll(fd, reinterpret_cast<const char*>(payload.data()), payload.size(), writeErrno)) {
        closeBestEffort(fd);
        return fail(createFsError(globalObject, vm, writeErrno, "write"_s, path));
    }
    closeBestEffort(fd);
    return ok(JSC::jsUndefined());
}

FsResult mkdirOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::CString path;
    JSC::JSValue error;
    if (!pathArgument(globalObject, scope, callFrame, 0, path, error))
        return fail(error);

    RoutedPath routed;
    if (!routeFsPath(globalObject, vm, path, "mkdir"_s, routed, error))
        return fail(error);
    if (routed.klass != routeClassTmp)
        return fail(createFsError(globalObject, vm, EROFS, "mkdir"_s, path));
    if (sysMkdirAt(routed.normalized, 0700) != 0)
        return fail(createFsError(globalObject, vm, errno, "mkdir"_s, path));
    return ok(JSC::jsUndefined());
}

FsResult unlinkOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::CString path;
    JSC::JSValue error;
    if (!pathArgument(globalObject, scope, callFrame, 0, path, error))
        return fail(error);

    RoutedPath routed;
    if (!routeFsPath(globalObject, vm, path, "unlink"_s, routed, error))
        return fail(error);
    if (routed.klass != routeClassTmp)
        return fail(createFsError(globalObject, vm, EROFS, "unlink"_s, path));
    if (sysUnlinkAt(routed.normalized) != 0)
        return fail(createFsError(globalObject, vm, errno, "unlink"_s, path));
    return ok(JSC::jsUndefined());
}

FsResult renameOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::CString oldPath;
    WTF::CString newPath;
    JSC::JSValue error;
    if (!pathArgument(globalObject, scope, callFrame, 0, oldPath, error))
        return fail(error);
    if (!pathArgument(globalObject, scope, callFrame, 1, newPath, error))
        return fail(error);

    RoutedPath oldRouted;
    if (!routeFsPath(globalObject, vm, oldPath, "rename"_s, oldRouted, error))
        return fail(error);
    RoutedPath newRouted;
    if (!routeFsPath(globalObject, vm, newPath, "rename"_s, newRouted, error))
        return fail(error);
    // Both ends must be under /tmp; a rename from or into any other namespace fails with EROFS.
    if (oldRouted.klass != routeClassTmp || newRouted.klass != routeClassTmp)
        return fail(createFsErrorWithDest(globalObject, vm, EROFS, "rename"_s, oldPath, newPath));
    if (sysRenameAt2(oldRouted.normalized, newRouted.normalized) != 0)
        return fail(createFsErrorWithDest(globalObject, vm, errno, "rename"_s, oldPath, newPath));
    return ok(JSC::jsUndefined());
}

FsResult readdirOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::CString path;
    JSC::JSValue error;
    if (!pathArgument(globalObject, scope, callFrame, 0, path, error))
        return fail(error);

    RoutedPath routed;
    if (!routeFsPath(globalObject, vm, path, "openat"_s, routed, error))
        return fail(error);
    if (routed.klass == routeClassDeployDir) {
        // A directory of the tree lists from the index alone: its immediate children in the index's byte order, each
        // subdirectory once. The tree and /tmp never overlap, so nothing local is merged in, and the virtual "/" and
        // "/var" list the namespace roots through the same call. `entries_max` in common/ipc/fs_index.zig bounds a
        // listing.
        auto* array = JSC::constructEmptyArray(globalObject, nullptr);
        uint64_t cursor = readdirCursorStart;
        char nameBuffer[routeNameCapacity];
        unsigned index = 0;
        for (;;) {
            uint32_t nameLen = 0;
            uint8_t isDir = 0;
            int32_t rc = collo_worker_fs_readdir_next(
                routed.normalized, routed.normalizedLen, &cursor, nameBuffer, sizeof(nameBuffer), &nameLen, &isDir);
            if (rc == 0)
                break;
            if (rc < 0)
                return fail(createFsError(globalObject, vm, EIO, "getdents64"_s, path));
            array->putDirectIndex(globalObject, index++,
                JSC::jsString(vm,
                    stringFromUtf8Bytes(
                        std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(nameBuffer), nameLen })));
        }
        return ok(array);
    }
    if (routed.klass == routeClassDeployFile)
        return fail(createFsError(globalObject, vm, ENOTDIR, "openat"_s, path));
    if (routed.klass == routeClassNone)
        return fail(createFsError(globalObject, vm, ENOENT, "openat"_s, path));

    int fd = sysOpenAt(routed.normalized, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (fd < 0)
        return fail(createFsError(globalObject, vm, errno, "openat"_s, path));

    auto* array = JSC::constructEmptyArray(globalObject, nullptr);
    uint8_t buffer[getdentsBufferBytes];
    unsigned index = 0;
    for (;;) {
        long rc = syscall(SYS_getdents64, fd, buffer, sizeof(buffer));
        if (rc > 0) {
            size_t offset = 0;
            while (offset < static_cast<size_t>(rc)) {
                auto* entry = reinterpret_cast<LinuxDirent64*>(buffer + offset);
                if (entry->reclen == 0 || offset + entry->reclen > static_cast<size_t>(rc)) {
                    closeBestEffort(fd);
                    return fail(createFsError(globalObject, vm, EIO, "getdents64"_s, path));
                }
                WTF::String name = stringFromCString(entry->name);
                // No entry cap, for the reason given at maxReadFileBytes.
                if (name != "."_s && name != ".."_s)
                    array->putDirectIndex(globalObject, index++, JSC::jsString(vm, name));
                offset += entry->reclen;
            }
            continue;
        }
        if (rc == 0)
            break;
        if (errno == EINTR)
            continue;
        int savedErrno = errno;
        closeBestEffort(fd);
        return fail(createFsError(globalObject, vm, savedErrno, "getdents64"_s, path));
    }
    closeBestEffort(fd);
    return ok(array);
}

JSC::EncodedJSValue encodeSyncResult(JSC::JSGlobalObject* globalObject, FsResult&& result)
{
    if (result.ok)
        return JSC::JSValue::encode(result.value);
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    return JSC::JSValue::encode(JSC::throwException(globalObject, scope, result.error));
}

JSC::EncodedJSValue encodePromiseResult(JSC::JSGlobalObject* globalObject, FsResult&& result)
{
    if (result.pending)
        return JSC::JSValue::encode(result.value);
    if (result.ok)
        return Collo::HostFunctions::resolvedPromise(globalObject, result.value);
    return Collo::HostFunctions::rejectedPromise(globalObject, result.error);
}

JSC_DEFINE_HOST_FUNCTION(fsReadFileSync, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodeSyncResult(globalObject, readFileOperation(globalObject, callFrame, /* allowAsyncFault */ false));
}

JSC_DEFINE_HOST_FUNCTION(fsWriteFileSync, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodeSyncResult(globalObject, writeFileOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsMkdirSync, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodeSyncResult(globalObject, mkdirOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsReaddirSync, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodeSyncResult(globalObject, readdirOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsStatSync, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodeSyncResult(globalObject, statOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsUnlinkSync, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodeSyncResult(globalObject, unlinkOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsRenameSync, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodeSyncResult(globalObject, renameOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsExistsSync, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodeSyncResult(globalObject, existsOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsReadFile, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodePromiseResult(globalObject, readFileOperation(globalObject, callFrame, /* allowAsyncFault */ true));
}

JSC_DEFINE_HOST_FUNCTION(fsWriteFile, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodePromiseResult(globalObject, writeFileOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsMkdir, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodePromiseResult(globalObject, mkdirOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsReaddir, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodePromiseResult(globalObject, readdirOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsStat, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodePromiseResult(globalObject, statOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsUnlink, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodePromiseResult(globalObject, unlinkOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsRename, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodePromiseResult(globalObject, renameOperation(globalObject, callFrame));
}

JSC_DEFINE_HOST_FUNCTION(fsExists, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodePromiseResult(globalObject, existsOperation(globalObject, callFrame));
}

void putFsFunction(JSC::JSGlobalObject* globalObject, JSC::JSObject* object, JSC::VM& vm, WTF::ASCIILiteral name,
    unsigned length, JSC::NativeFunction function)
{
    Collo::HostFunctions::putWebApiFunction(globalObject, object, vm, name, length, function, fsPropertyAttributes);
}

} // namespace

namespace Collo::HostFunctions {

void installNodeFs(Collo::GlobalObject* globalObject, JSC::VM& vm)
{
    auto* fsObject = JSC::constructEmptyObject(globalObject);
    auto* promisesObject = JSC::constructEmptyObject(globalObject);

    putFsFunction(globalObject, fsObject, vm, "readFileSync"_s, 1, fsReadFileSync);
    putFsFunction(globalObject, fsObject, vm, "writeFileSync"_s, 2, fsWriteFileSync);
    putFsFunction(globalObject, fsObject, vm, "mkdirSync"_s, 1, fsMkdirSync);
    putFsFunction(globalObject, fsObject, vm, "readdirSync"_s, 1, fsReaddirSync);
    putFsFunction(globalObject, fsObject, vm, "statSync"_s, 1, fsStatSync);
    putFsFunction(globalObject, fsObject, vm, "unlinkSync"_s, 1, fsUnlinkSync);
    putFsFunction(globalObject, fsObject, vm, "renameSync"_s, 2, fsRenameSync);
    putFsFunction(globalObject, fsObject, vm, "existsSync"_s, 1, fsExistsSync);

    putFsFunction(globalObject, fsObject, vm, "readFile"_s, 1, fsReadFile);
    putFsFunction(globalObject, fsObject, vm, "writeFile"_s, 2, fsWriteFile);
    putFsFunction(globalObject, fsObject, vm, "mkdir"_s, 1, fsMkdir);
    putFsFunction(globalObject, fsObject, vm, "readdir"_s, 1, fsReaddir);
    putFsFunction(globalObject, fsObject, vm, "stat"_s, 1, fsStat);
    putFsFunction(globalObject, fsObject, vm, "unlink"_s, 1, fsUnlink);
    putFsFunction(globalObject, fsObject, vm, "rename"_s, 2, fsRename);
    putFsFunction(globalObject, fsObject, vm, "exists"_s, 1, fsExists);

    putFsFunction(globalObject, promisesObject, vm, "readFile"_s, 1, fsReadFile);
    putFsFunction(globalObject, promisesObject, vm, "writeFile"_s, 2, fsWriteFile);
    putFsFunction(globalObject, promisesObject, vm, "mkdir"_s, 1, fsMkdir);
    putFsFunction(globalObject, promisesObject, vm, "readdir"_s, 1, fsReaddir);
    putFsFunction(globalObject, promisesObject, vm, "stat"_s, 1, fsStat);
    putFsFunction(globalObject, promisesObject, vm, "unlink"_s, 1, fsUnlink);
    putFsFunction(globalObject, promisesObject, vm, "rename"_s, 2, fsRename);
    putFsFunction(globalObject, promisesObject, vm, "exists"_s, 1, fsExists);

    fsObject->putDirect(vm, JSC::Identifier::fromString(vm, "promises"_s), promisesObject,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly));
    JSC::objectConstructorFreeze(globalObject, promisesObject);
    JSC::objectConstructorFreeze(globalObject, fsObject);
    globalObject->putDirect(vm, JSC::Identifier::fromString(vm, "__collo_node_fs"_s), fsObject,
        static_cast<unsigned>(
            JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontDelete));
}

} // namespace Collo::HostFunctions
