// The `node:fs` binding: readFile, writeFile, mkdir, readdir, stat, unlink, rename and exists, each as a `*Sync`
// function and as a promise-returning one, gathered on the frozen global `__collo_node_fs` that module_loader.cpp's
// `node:fs` and `node:fs/promises` modules re-export. The functions without the suffix return promises, like their
// `fs.promises` twins, and take no callback. It runs on the VM thread of a worker, which installs it after its seccomp
// filter, and it is the one place the bridge performs file I/O.
//
// What confines node:fs is the worker's sandbox, so node:fs is closed in any process the sandbox does not confine.
// Every operation first checks a process-wide flag that only openNodeFsForProcess sets, and fails with EPERM while it
// is clear; installing the binding opens nothing.
//
// Every operation passes the caller's path to its syscall as given, with AT_FDCWD as the directory, so the kernel
// resolves it inside the worker's root: a relative path from the working directory the sandbox sets, and `..` never
// above the chroot (zygote/worker_boot/sandbox.zig). The kernel also decides what may be written. The sandbox mounts
// the root read-only except /tmp, so a write anywhere else fails with EROFS, and a rename between /tmp and the rest of
// the root fails with EXDEV, whoever makes the call. Nothing here classifies a path or calls into Zig. Each syscall
// passes only flags the worker's seccomp filter admits; the filter fails any other flag, or any directory but AT_FDCWD,
// with EPERM. Every fd is opened close-on-exec and closed before the call that opened it returns.
//
// The promise forms run the same blocking syscalls on the VM thread and return a promise that is already settled. A
// read or a listing has no cap of its own: its buffers are charged to the worker's cgroup, and an allocation that fails
// becomes an OutOfMemoryError. The one exception is the decoded string of a UTF-8 read, which WTF allocates with an
// allocator that ends the process when it fails (host_functions/webapi/encoding/utf8.h), so that failure ends the
// worker.
//
// An errno failure throws or rejects with an Error carrying Node's `code`, `errno`, `syscall` and `path` properties,
// plus `dest` for rename. An argument of the wrong type or value fails with a TypeError carrying Node's
// ERR_INVALID_ARG_TYPE or ERR_INVALID_ARG_VALUE code, except in exists, which answers false as Node's existsSync does.

#include "host_functions/node/fs.h"

// For createBodyUint8ArrayCopy, which readFile shares with the fetch body readers.
#include "host_functions/server/fetch/body_utils.h"
#include "host_functions/support.h"
#include "host_functions/webapi/encoding/utf8.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <wtf/CheckedArithmetic.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringView.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <span>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace {

// Whether node:fs may reach the filesystem in this process. Only openNodeFsForProcess sets it, and nothing clears it.
// collo_vm_enable_node_fs_for_worker calls that function, and a worker's child boot calls the enable only after its
// seccomp filter is installed (zygote/child_boot.zig); the zygote never does. So a binding installed in a process the
// sandbox does not confine, such as the zygote and every child before that call, answers EPERM instead of reaching
// the host's files with the server's uid. Constant-initialized, so it needs no global constructor.
constinit std::atomic<bool> node_fs_open { false };

// The read size per pass once readFile's buffer is full, when a file has grown past the size fstat reported.
constexpr size_t readGrowthBytes = 16 * 1024;
constexpr size_t getdentsBufferBytes = 16 * 1024;
constexpr unsigned fsPropertyAttributes = static_cast<unsigned>(JSC::PropertyAttribute::DontEnum);

// The kernel's struct linux_dirent64 (include/linux/dirent.h), the record getdents64 fills its buffer with: `d_reclen`
// at byte 16 is the length of the whole record with its padding, and the NUL-terminated `d_name` starts at byte 19.
constexpr size_t direntReclenOffset = 16;
constexpr size_t direntNameOffset = 19;

struct FsResult {
    JSC::JSValue value { JSC::jsUndefined() };
    JSC::JSValue error { JSC::jsUndefined() };
    bool ok { false };
};

// A path argument in the two forms an operation needs: the string the caller passed, which an error reports as given,
// and its UTF-8 bytes with a trailing NUL, which the syscalls receive.
struct FsPath {
    WTF::String text;
    WTF::CString bytes;
};

// Owns a descriptor an operation opened and closes it when the operation returns, on every path. It cannot be copied,
// so each descriptor is closed once.
class OwnedFd {
public:
    explicit OwnedFd(int fd)
        : m_fd(fd)
    {
    }

    ~OwnedFd()
    {
        if (m_fd >= 0)
            close(m_fd);
    }

    OwnedFd(const OwnedFd&) = delete;
    OwnedFd& operator=(const OwnedFd&) = delete;

    explicit operator bool() const { return m_fd >= 0; }
    int get() const { return m_fd; }

private:
    int m_fd;
};

// For short text only, a strerror message or a directory entry's name, which the kernel bounds at NAME_MAX bytes:
// a file's contents go through the checked decode in utf8.h instead.
WTF::String stringFromUtf8Bytes(std::span<const uint8_t> bytes)
{
    return WTF::String::fromUTF8ReplacingInvalidSequences(byteCast<char8_t>(bytes));
}

WTF::String stringFromCString(const char* text)
{
    return stringFromUtf8Bytes(byteCast<uint8_t>(std::span { text, std::strlen(text) }));
}

// The `code` Node reports for an errno: its name, for every errno the syscalls in this file can return. Any other
// errno reports EIO, while the error's `errno` and message keep the real value.
WTF::ASCIILiteral errnoCode(int err)
{
    switch (err) {
    case EACCES:
        return "EACCES"_s;
    case EAGAIN:
        return "EAGAIN"_s;
    case EBADF:
        return "EBADF"_s;
    case EBUSY:
        return "EBUSY"_s;
    case EDQUOT:
        return "EDQUOT"_s;
    case EEXIST:
        return "EEXIST"_s;
    case EFAULT:
        return "EFAULT"_s;
    case EFBIG:
        return "EFBIG"_s;
    case EINVAL:
        return "EINVAL"_s;
    case EIO:
        return "EIO"_s;
    case EISDIR:
        return "EISDIR"_s;
    case ELOOP:
        return "ELOOP"_s;
    case EMFILE:
        return "EMFILE"_s;
    case EMLINK:
        return "EMLINK"_s;
    case ENAMETOOLONG:
        return "ENAMETOOLONG"_s;
    case ENFILE:
        return "ENFILE"_s;
    case ENODEV:
        return "ENODEV"_s;
    case ENOENT:
        return "ENOENT"_s;
    case ENOMEM:
        return "ENOMEM"_s;
    case ENOSPC:
        return "ENOSPC"_s;
    case ENOTDIR:
        return "ENOTDIR"_s;
    case ENOTEMPTY:
        return "ENOTEMPTY"_s;
    case ENXIO:
        return "ENXIO"_s;
    case EOPNOTSUPP:
        return "EOPNOTSUPP"_s;
    case EOVERFLOW:
        return "EOVERFLOW"_s;
    case EPERM:
        return "EPERM"_s;
    case EROFS:
        return "EROFS"_s;
    case ETXTBSY:
        return "ETXTBSY"_s;
    case EXDEV:
        return "EXDEV"_s;
    default:
        return "EIO"_s;
    }
}

// Puts the non-enumerable `code`, `errno` (negative, as Node reports it) and `syscall` properties of an errno failure.
void putErrnoProperties(JSC::VM& vm, JSC::JSObject* error, int err, WTF::ASCIILiteral syscallName)
{
    error->putDirect(vm, JSC::Identifier::fromString(vm, "code"_s), JSC::jsString(vm, WTF::String(errnoCode(err))),
        fsPropertyAttributes);
    error->putDirect(vm, JSC::Identifier::fromString(vm, "errno"_s), JSC::jsNumber(-err), fsPropertyAttributes);
    error->putDirect(vm, JSC::Identifier::fromString(vm, "syscall"_s), JSC::jsString(vm, WTF::String(syscallName)),
        fsPropertyAttributes);
}

// The Error of every errno failure: the message "<syscall> '<path>' failed: <strerror text>", the errno properties and
// a non-enumerable `path`, which keeps the whole string as given. A path too long to fit in a message with the rest
// leaves it out of the message rather than ending the worker, which makeString would do.
JSC::JSObject* createFsError(
    JSC::JSGlobalObject* globalObject, JSC::VM& vm, int err, WTF::ASCIILiteral syscallName, const WTF::String& path)
{
    WTF::String reason = stringFromCString(std::strerror(err));
    WTF::String message = WTF::tryMakeString(syscallName, " '"_s, path, "' failed: "_s, reason);
    if (message.isNull())
        message = WTF::makeString(syscallName, " failed: "_s, reason);
    auto* error = JSC::createError(globalObject, message);
    putErrnoProperties(vm, error, err, syscallName);
    error->putDirect(vm, JSC::Identifier::fromString(vm, "path"_s), JSC::jsString(vm, path), fsPropertyAttributes);
    return error;
}

// The failure of every operation while node:fs is closed in this process (`node_fs_open`): an EPERM Error without a
// path, since no argument has been read.
JSC::JSObject* createClosedFsError(JSC::JSGlobalObject* globalObject, JSC::VM& vm, WTF::ASCIILiteral syscallName)
{
    auto* error = JSC::createError(
        globalObject, WTF::makeString(syscallName, " refused: node:fs is not open in this process"_s));
    putErrnoProperties(vm, error, EPERM, syscallName);
    return error;
}

// A rename's errno failure, which also carries the destination as `dest`.
JSC::JSObject* createFsErrorWithDest(JSC::JSGlobalObject* globalObject, JSC::VM& vm, int err,
    WTF::ASCIILiteral syscallName, const WTF::String& path, const WTF::String& dest)
{
    auto* error = createFsError(globalObject, vm, err, syscallName, path);
    error->putDirect(vm, JSC::Identifier::fromString(vm, "dest"_s), JSC::jsString(vm, dest), fsPropertyAttributes);
    return error;
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

FsResult ok(JSC::JSValue value) { return { value, JSC::jsUndefined(), true }; }

FsResult fail(JSC::JSValue error) { return { JSC::jsUndefined(), error, false }; }

// Takes the exception pending on `scope` as an operation's failure. A termination stays pending, because
// tryClearException refuses to clear one, and the encoders at the end of this file return no value while it is.
JSC::JSValue takeException(JSC::ThrowScope& scope)
{
    JSC::JSValue error = scope.exception()->value();
    (void)scope.tryClearException();
    return error;
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

// How reading a path argument ended: a path, the caller's misuse (the TypeErrors Node gives a path it cannot validate),
// or a failure of the engine's own (an allocation, a pending exception).
enum class PathArgument : uint8_t {
    valid,
    invalid,
    failed,
};

PathArgument pathArgument(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, JSC::CallFrame* callFrame,
    unsigned index, FsPath& out, JSC::JSValue& outError)
{
    JSC::VM& vm = globalObject->vm();
    if (callFrame->argumentCount() <= index || callFrame->argument(index).isUndefined()) {
        outError
            = createTypeErrorWithCode(globalObject, vm, "ERR_INVALID_ARG_TYPE"_s, "fs path argument is required."_s);
        return PathArgument::invalid;
    }

    // Only a string is a path, and the type is checked before any conversion, so a number or an object never becomes
    // a lookup of its string form and a Symbol fails with a coded TypeError. Node also accepts a Buffer or URL path;
    // here both fail with ERR_INVALID_ARG_TYPE.
    JSC::JSValue pathValue = callFrame->argument(index);
    if (!pathValue.isString()) {
        outError = createTypeErrorWithCode(globalObject, vm, "ERR_INVALID_ARG_TYPE"_s, "fs path must be a string."_s);
        return PathArgument::invalid;
    }

    out.text = pathValue.toWTFString(globalObject);
    if (scope.exception()) {
        outError = takeException(scope);
        return PathArgument::failed;
    }

    // The kernel reads a path up to its first NUL, so a path holding one would name a different file than the string.
    if (out.text.contains(static_cast<char16_t>(0))) {
        outError = createTypeErrorWithCode(
            globalObject, vm, "ERR_INVALID_ARG_VALUE"_s, "fs path must not contain NUL bytes."_s);
        return PathArgument::invalid;
    }

    // The lenient conversion fails only when the UTF-8 form would be longer than WTF converts; a failed allocation
    // inside it still ends the process, as everywhere in WTF. An empty path reaches the kernel, which answers ENOENT,
    // as it does for Node.
    auto bytes = out.text.tryGetUTF8();
    if (!bytes) {
        outError = JSC::createOutOfMemoryError(globalObject);
        return PathArgument::failed;
    }
    out.bytes = WTF::move(bytes.value());
    return PathArgument::valid;
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
        return byteCast<uint8_t>(string.span());
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
        outError = takeException(scope);
        return false;
    }
    // As for a path, the conversion fails only when the UTF-8 form would be longer than WTF converts.
    auto string = stringValue.tryGetUTF8();
    if (!string) {
        outError = JSC::createOutOfMemoryError(globalObject);
        return false;
    }
    out.string = WTF::move(string.value());
    out.isBytes = false;
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
            outError = takeException(scope);
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
        outError = takeException(scope);
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

// readFile's result from the bytes read, in the form `output` selects.
FsResult encodeReadData(
    JSC::JSGlobalObject* globalObject, JSC::VM& vm, std::span<const uint8_t> bytes, ReadOutput output)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (output == ReadOutput::utf8) {
        // Node keeps a leading BOM as U+FEFF. utf8.h says which input the decode refuses with an OutOfMemoryError
        // instead of ending the process.
        WTF::String text;
        if (!Collo::HostFunctions::decodeUtf8BytesPreservingBom(globalObject, scope, bytes, text))
            return fail(takeException(scope));
        return ok(JSC::jsString(vm, WTF::move(text)));
    }
    auto* array = Collo::HostFunctions::createBodyUint8ArrayCopy(globalObject, scope, bytes);
    if (scope.exception())
        return fail(takeException(scope));
    if (!array)
        return fail(JSC::createOutOfMemoryError(globalObject));
    return ok(array);
}

// AT_FDCWD is a kernel `int`. Passed to the variadic syscall() as an int, it would reach the argument register through
// a 32-bit move that zeroes the high word. The worker's seccomp filter (zygote/worker_boot/sandbox.zig) compares only
// the low word, as the kernel reads it, so both forms pass; the sign-extended long keeps the whole register canonical
// and matches what Zig's `*at` wrappers pass.
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

// Writes all of `bytes` to `fd`, retrying short writes. Returns 0, or the errno of the write that failed; a write that
// accepts nothing without setting errno reports EIO.
int writeAll(int fd, std::span<const uint8_t> bytes)
{
    while (!bytes.empty()) {
        ssize_t rc = write(fd, bytes.data(), bytes.size());
        if (rc > 0) {
            bytes = bytes.subspan(static_cast<size_t>(rc));
            continue;
        }
        if (rc < 0 && errno == EINTR)
            continue;
        return rc < 0 ? errno : EIO;
    }
    return 0;
}

// Reads the file at `path` to its end. Only a regular file is read: a directory fails with EISDIR and any other kind
// of file with EINVAL. fstat's size is a hint, since the file may change while it is read. The buffer starts one byte
// past it, so a file of exactly that size ends with a read of zero bytes and no reallocation; whenever it fills, the
// next read asks for readGrowthBytes more, while Vector grows its capacity geometrically.
//
// The worker cannot create anything but directories and regular files, because its filter admits no mknodat, so its
// own root holds no FIFO. A FIFO in a directory bound from the host would block the open until a writer appears, since
// the filter admits no O_NONBLOCK, and only then would fstat refuse it.
FsResult readWholeFile(JSC::JSGlobalObject* globalObject, JSC::VM& vm, const FsPath& path, ReadOutput output)
{
    OwnedFd fd(sysOpenAt(path.bytes.data(), O_RDONLY | O_CLOEXEC, 0));
    if (!fd)
        return fail(createFsError(globalObject, vm, errno, "openat"_s, path.text));

    struct stat statBuffer;
    if (fstat(fd.get(), &statBuffer) != 0)
        return fail(createFsError(globalObject, vm, errno, "fstat"_s, path.text));
    if (S_ISDIR(statBuffer.st_mode))
        return fail(createFsError(globalObject, vm, EISDIR, "read"_s, path.text));
    if (!S_ISREG(statBuffer.st_mode))
        return fail(createFsError(globalObject, vm, EINVAL, "read"_s, path.text));

    // A regular file's st_size is never negative.
    CheckedSize capacity = static_cast<size_t>(statBuffer.st_size);
    capacity += size_t { 1 };
    WTF::Vector<uint8_t> bytes;
    if (capacity.hasOverflowed() || !bytes.tryGrow(capacity.value()))
        return fail(JSC::createOutOfMemoryError(globalObject));
    size_t length = 0;
    for (;;) {
        if (length == bytes.size()) {
            CheckedSize grown = bytes.size();
            grown += readGrowthBytes;
            if (grown.hasOverflowed() || !bytes.tryGrow(grown.value()))
                return fail(JSC::createOutOfMemoryError(globalObject));
        }
        std::span<uint8_t> unfilled = bytes.mutableSpan().subspan(length);
        ssize_t rc = read(fd.get(), unfilled.data(), unfilled.size());
        if (rc > 0) {
            length += static_cast<size_t>(rc);
            continue;
        }
        if (!rc)
            break;
        if (errno != EINTR)
            return fail(createFsError(globalObject, vm, errno, "read"_s, path.text));
    }
    bytes.shrink(length);
    return encodeReadData(globalObject, vm, bytes.span(), output);
}

// Every operation starts here, before it reads an argument: false, with `out` set to the EPERM failure, while node:fs
// is closed in this process.
bool nodeFsOpen(JSC::JSGlobalObject* globalObject, JSC::VM& vm, WTF::ASCIILiteral syscallName, FsResult& out)
{
    if (node_fs_open.load())
        return true;
    out = fail(createClosedFsError(globalObject, vm, syscallName));
    return false;
}

FsResult statOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    FsResult closed;
    if (!nodeFsOpen(globalObject, vm, "stat"_s, closed))
        return closed;
    auto scope = DECLARE_THROW_SCOPE(vm);

    FsPath path;
    JSC::JSValue error;
    if (pathArgument(globalObject, scope, callFrame, 0, path, error) != PathArgument::valid)
        return fail(error);

    struct stat statBuffer;
    if (sysNewFstatAt(path.bytes.data(), &statBuffer) != 0)
        return fail(createFsError(globalObject, vm, errno, "stat"_s, path.text));
    return ok(makeStatObject(globalObject, vm, static_cast<uint64_t>(statBuffer.st_size), statBuffer.st_mode,
        mtimeMsFromTimespec(statBuffer.st_mtim)));
}

FsResult existsOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    FsResult closed;
    if (!nodeFsOpen(globalObject, vm, "stat"_s, closed))
        return closed;
    auto scope = DECLARE_THROW_SCOPE(vm);

    // As Node's existsSync does, a path argument that is missing, not a string or holds a NUL answers false. An
    // allocation failure or a pending termination still fails.
    FsPath path;
    JSC::JSValue error;
    switch (pathArgument(globalObject, scope, callFrame, 0, path, error)) {
    case PathArgument::valid:
        break;
    case PathArgument::invalid:
        return ok(JSC::jsBoolean(false));
    case PathArgument::failed:
        return fail(error);
    }

    // So does every failure of the stat: a missing file, a path too long, a component that is not a directory.
    struct stat statBuffer;
    return ok(JSC::jsBoolean(sysNewFstatAt(path.bytes.data(), &statBuffer) == 0));
}

FsResult readFileOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    FsResult closed;
    if (!nodeFsOpen(globalObject, vm, "openat"_s, closed))
        return closed;
    auto scope = DECLARE_THROW_SCOPE(vm);

    FsPath path;
    JSC::JSValue error;
    if (pathArgument(globalObject, scope, callFrame, 0, path, error) != PathArgument::valid)
        return fail(error);

    ReadOutput output = ReadOutput::bytes;
    if (!parseReadEncoding(globalObject, scope, callFrame, 1, output, error))
        return fail(error);

    return readWholeFile(globalObject, vm, path, output);
}

FsResult writeFileOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    FsResult closed;
    if (!nodeFsOpen(globalObject, vm, "openat"_s, closed))
        return closed;
    auto scope = DECLARE_THROW_SCOPE(vm);

    FsPath path;
    JSC::JSValue error;
    if (pathArgument(globalObject, scope, callFrame, 0, path, error) != PathArgument::valid)
        return fail(error);

    WriteData data;
    if (!writeDataArgument(globalObject, scope, callFrame, 1, data, error))
        return fail(error);

    OwnedFd fd(sysOpenAt(path.bytes.data(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600));
    if (!fd)
        return fail(createFsError(globalObject, vm, errno, "openat"_s, path.text));
    if (int writeErrno = writeAll(fd.get(), data.span()))
        return fail(createFsError(globalObject, vm, writeErrno, "write"_s, path.text));
    return ok(JSC::jsUndefined());
}

FsResult mkdirOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    FsResult closed;
    if (!nodeFsOpen(globalObject, vm, "mkdir"_s, closed))
        return closed;
    auto scope = DECLARE_THROW_SCOPE(vm);

    FsPath path;
    JSC::JSValue error;
    if (pathArgument(globalObject, scope, callFrame, 0, path, error) != PathArgument::valid)
        return fail(error);

    if (sysMkdirAt(path.bytes.data(), 0700) != 0)
        return fail(createFsError(globalObject, vm, errno, "mkdir"_s, path.text));
    return ok(JSC::jsUndefined());
}

FsResult unlinkOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    FsResult closed;
    if (!nodeFsOpen(globalObject, vm, "unlink"_s, closed))
        return closed;
    auto scope = DECLARE_THROW_SCOPE(vm);

    FsPath path;
    JSC::JSValue error;
    if (pathArgument(globalObject, scope, callFrame, 0, path, error) != PathArgument::valid)
        return fail(error);

    if (sysUnlinkAt(path.bytes.data()) != 0)
        return fail(createFsError(globalObject, vm, errno, "unlink"_s, path.text));
    return ok(JSC::jsUndefined());
}

FsResult renameOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    FsResult closed;
    if (!nodeFsOpen(globalObject, vm, "rename"_s, closed))
        return closed;
    auto scope = DECLARE_THROW_SCOPE(vm);

    FsPath oldPath;
    FsPath newPath;
    JSC::JSValue error;
    if (pathArgument(globalObject, scope, callFrame, 0, oldPath, error) != PathArgument::valid)
        return fail(error);
    if (pathArgument(globalObject, scope, callFrame, 1, newPath, error) != PathArgument::valid)
        return fail(error);

    if (sysRenameAt2(oldPath.bytes.data(), newPath.bytes.data()) != 0)
        return fail(createFsErrorWithDest(globalObject, vm, errno, "rename"_s, oldPath.text, newPath.text));
    return ok(JSC::jsUndefined());
}

// One entry's name inside readdir's buffer of names.
struct NameRange {
    size_t offset;
    size_t length;
};

// Lists a directory's entries without "." and "..", sorted by the bytes of their names as libuv's scandir sorts them
// for Node (strcmp), so a listing never depends on the order the kernel returns. The sort runs before the names are
// decoded, because UTF-16 code units put an astral character's surrogates before U+E000–U+FFFF, the reverse of the
// order of their UTF-8 bytes, and a name that is not UTF-8 decodes to U+FFFD.
FsResult readdirOperation(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = globalObject->vm();
    FsResult closed;
    if (!nodeFsOpen(globalObject, vm, "openat"_s, closed))
        return closed;
    auto scope = DECLARE_THROW_SCOPE(vm);

    FsPath path;
    JSC::JSValue error;
    if (pathArgument(globalObject, scope, callFrame, 0, path, error) != PathArgument::valid)
        return fail(error);

    OwnedFd fd(sysOpenAt(path.bytes.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0));
    if (!fd)
        return fail(createFsError(globalObject, vm, errno, "openat"_s, path.text));

    // Every name's bytes, back to back, and where each one lies.
    WTF::Vector<uint8_t> name_bytes;
    WTF::Vector<NameRange> name_ranges;
    uint8_t buffer[getdentsBufferBytes];
    for (;;) {
        long rc = syscall(SYS_getdents64, fd.get(), buffer, sizeof(buffer));
        if (rc < 0) {
            if (errno == EINTR)
                continue;
            return fail(createFsError(globalObject, vm, errno, "getdents64"_s, path.text));
        }
        if (!rc)
            break;

        std::span<const uint8_t> records = std::span<const uint8_t> { buffer }.first(static_cast<size_t>(rc));
        while (!records.empty()) {
            uint16_t recordLength = 0;
            if (records.size() <= direntNameOffset)
                return fail(createFsError(globalObject, vm, EIO, "getdents64"_s, path.text));
            memcpySpan(asMutableByteSpan(recordLength), records.subspan(direntReclenOffset, sizeof(recordLength)));
            if (recordLength <= direntNameOffset || recordLength > records.size())
                return fail(createFsError(globalObject, vm, EIO, "getdents64"_s, path.text));

            std::span<const uint8_t> nameField = records.subspan(direntNameOffset, recordLength - direntNameOffset);
            records = records.subspan(recordLength);
            auto nameEnd = std::find(nameField.begin(), nameField.end(), 0);
            if (nameEnd == nameField.end())
                return fail(createFsError(globalObject, vm, EIO, "getdents64"_s, path.text));
            std::span<const uint8_t> name = nameField.first(static_cast<size_t>(nameEnd - nameField.begin()));
            bool isDot = name.size() == 1 && name[0] == '.';
            bool isDotDot = name.size() == 2 && name[0] == '.' && name[1] == '.';
            if (isDot || isDotDot)
                continue;
            // No entry cap, for the reason the file header gives.
            const NameRange range { name_bytes.size(), name.size() };
            if (!name_bytes.tryAppend(name) || !name_ranges.tryAppend(range))
                return fail(JSC::createOutOfMemoryError(globalObject));
        }
    }

    const std::span<const uint8_t> all_names = name_bytes.span();
    auto name_of = [all_names](const NameRange& range) { return all_names.subspan(range.offset, range.length); };
    // uint8_t compares unsigned, as strcmp compares its bytes.
    std::sort(name_ranges.begin(), name_ranges.end(), [&name_of](const NameRange& left, const NameRange& right) {
        const auto left_name = name_of(left);
        const auto right_name = name_of(right);
        return std::lexicographical_compare(left_name.begin(), left_name.end(), right_name.begin(), right_name.end());
    });
    auto* array = JSC::constructEmptyArray(globalObject, nullptr);
    if (scope.exception())
        return fail(takeException(scope));
    for (unsigned index = 0; index < name_ranges.size(); ++index) {
        array->putDirectIndex(globalObject, index, JSC::jsString(vm, stringFromUtf8Bytes(name_of(name_ranges[index]))));
        if (scope.exception())
            return fail(takeException(scope));
    }
    return ok(array);
}

// A termination that takeException could not clear is still pending here, and the VM keeps unwinding it without a
// result, so neither encoder throws again or creates a promise while one is.
JSC::EncodedJSValue encodeSyncResult(JSC::JSGlobalObject* globalObject, FsResult&& result)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    RETURN_IF_EXCEPTION(scope, {});
    if (result.ok)
        return JSC::JSValue::encode(result.value);
    return JSC::JSValue::encode(JSC::throwException(globalObject, scope, result.error));
}

JSC::EncodedJSValue encodePromiseResult(JSC::JSGlobalObject* globalObject, FsResult&& result)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    RETURN_IF_EXCEPTION(scope, {});
    if (result.ok)
        RELEASE_AND_RETURN(scope, Collo::HostFunctions::resolvedPromise(globalObject, result.value));
    RELEASE_AND_RETURN(scope, Collo::HostFunctions::rejectedPromise(globalObject, result.error));
}

JSC_DEFINE_HOST_FUNCTION(fsReadFileSync, (JSC::JSGlobalObject * globalObject, JSC::CallFrame* callFrame))
{
    return encodeSyncResult(globalObject, readFileOperation(globalObject, callFrame));
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
    return encodePromiseResult(globalObject, readFileOperation(globalObject, callFrame));
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

void openNodeFsForProcess() { node_fs_open.store(true); }

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
