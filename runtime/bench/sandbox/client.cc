// Persistent loopback client; transport setup and /__collo/healthz precede measured GETs.
#include "client.h"
#include <arpa/inet.h>
#include <lshpack.h>
#include <memory>
#include <netinet/tcp.h>
#include <new>
#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

namespace {
constexpr size_t frameLimit = 16384;
constexpr size_t bodyLimit = 1 << 20;
constexpr unsigned frameCountLimit = 4096;

uint64_t monotonicNs()
{
    timespec time {};
    if (clock_gettime(CLOCK_MONOTONIC, &time) || time.tv_sec < 0)
        return 0;
    return static_cast<uint64_t>(time.tv_sec) * 1000000000ULL + time.tv_nsec;
}

uint32_t read32(const uint8_t* bytes)
{
    return uint32_t(bytes[0]) << 24 | uint32_t(bytes[1]) << 16 | uint32_t(bytes[2]) << 8 | bytes[3];
}

void write32(uint8_t* bytes, uint32_t value)
{
    for (unsigned i = 0; i < 4; ++i)
        bytes[i] = static_cast<uint8_t>(value >> (24 - i * 8));
}

void frameHeader(uint8_t* bytes, size_t length, uint8_t type, uint8_t flags, uint32_t stream)
{
    bytes[0] = static_cast<uint8_t>(length >> 16);
    bytes[1] = static_cast<uint8_t>(length >> 8);
    bytes[2] = static_cast<uint8_t>(length);
    bytes[3] = type;
    bytes[4] = flags;
    write32(bytes + 5, stream);
}

uint8_t* literal(uint8_t* out, uint8_t nameIndex, const char* value, size_t length)
{
    *out++ = nameIndex;
    size_t remaining = length;
    *out++ = static_cast<uint8_t>(remaining < 127 ? remaining : 127);
    if (remaining >= 127) {
        remaining -= 127;
        while (remaining >= 128) {
            *out++ = static_cast<uint8_t>((remaining & 127) | 128);
            remaining >>= 7;
        }
        *out++ = static_cast<uint8_t>(remaining);
    }
    memcpy(out, value, length);
    return out + length;
}

// MSG_NOSIGNAL keeps peer disconnects local without changing process signal policy.
int socketWrite(BIO* bio, const char* bytes, int length)
{
    return static_cast<int>(send(*static_cast<int*>(BIO_get_data(bio)), bytes, length, MSG_NOSIGNAL));
}

int socketRead(BIO* bio, char* bytes, int length)
{
    return static_cast<int>(recv(*static_cast<int*>(BIO_get_data(bio)), bytes, length, 0));
}

long socketControl(BIO*, int command, long, void*) { return command == BIO_CTRL_FLUSH ? 1 : 0; }
}

struct ColloBenchClient {
    int fd { -1 };
    bssl::UniquePtr<SSL_CTX> context;
    bssl::UniquePtr<BIO_METHOD> method;
    bssl::UniquePtr<SSL> ssl;
    lshpack_dec decoder {};
    char authority[256] {};
    uint8_t payload[frameLimit];
    uint8_t block[32768];
    uint32_t nextStream { 1 };
    uint32_t connectionWindow { 65535 };
    uint32_t streamWindow { 65535 };
    uint32_t initialWindow { 65535 };
    bool peerSettings { false };
    bool settingsAck { false };
    struct Frame {
        size_t length;
        uint32_t stream;
        uint8_t type;
        uint8_t flags;
    };

    ColloBenchClient() { lshpack_dec_init(&decoder); }
    ~ColloBenchClient()
    {
        disconnect();
        lshpack_dec_cleanup(&decoder);
    }
    void disconnect()
    {
        ssl.reset();
        if (fd >= 0)
            close(fd);
        fd = -1;
    }
    bool write(const void* bytes, size_t length)
    {
        return SSL_write(ssl.get(), bytes, static_cast<int>(length)) == static_cast<int>(length);
    }
    bool read(void* bytes, size_t length)
    {
        auto* cursor = static_cast<uint8_t*>(bytes);
        while (length) {
            int count = SSL_read(ssl.get(), cursor, static_cast<int>(length));
            // Blocking socket timeouts and TLS failures end this trial; never spin on WANT_READ.
            if (count <= 0)
                return false;
            cursor += count;
            length -= static_cast<size_t>(count);
        }
        return true;
    }
    bool sendFrame(uint8_t type, uint8_t flags, uint32_t stream, const void* bytes, size_t length)
    {
        uint8_t frame[17];
        if (length > sizeof(frame) - 9)
            return false;
        frameHeader(frame, length, type, flags, stream);
        if (length)
            memcpy(frame + 9, bytes, length);
        return write(frame, length + 9);
    }
    bool readFrame(Frame& frame)
    {
        uint8_t header[9];
        if (!read(header, sizeof(header)))
            return false;
        frame = { size_t(header[0]) << 16 | size_t(header[1]) << 8 | header[2], read32(header + 5) & 0x7fffffff,
            header[3], header[4] };
        return frame.length <= sizeof(payload) && read(payload, frame.length);
    }
    bool control(const Frame& frame)
    {
        switch (frame.type) {
        case 4:
            if (frame.stream || frame.length % 6)
                return false;
            if (frame.flags & 1) {
                if (frame.length || settingsAck)
                    return false;
                settingsAck = true;
                return true;
            }
            for (size_t i = 0; i < frame.length; i += 6) {
                unsigned id = unsigned(payload[i]) << 8 | payload[i + 1];
                uint32_t value = read32(payload + i + 2);
                if (id == 2 || (id == 3 && !value) || (id == 4 && value > 0x7fffffff)
                    || (id == 5 && (value < 16384 || value > 0xffffff)))
                    return false;
                if (id == 4) {
                    uint64_t adjusted = uint64_t(streamWindow) + value - initialWindow;
                    if (adjusted > 0x7fffffff)
                        return false;
                    streamWindow = static_cast<uint32_t>(adjusted);
                    initialWindow = value;
                }
            }
            peerSettings = true;
            return sendFrame(4, 1, 0, nullptr, 0);
        case 6:
            return !frame.stream && frame.length == 8 && ((frame.flags & 1) || sendFrame(6, 1, 0, payload, 8));
        case 8: {
            if (frame.length != 4 || (frame.stream && (!(frame.stream & 1) || frame.stream >= nextStream)))
                return false;
            uint32_t credit = read32(payload) & 0x7fffffff;
            if (!credit)
                return false;
            if (frame.stream && frame.stream != nextStream - 2)
                return true;
            uint32_t& window = frame.stream ? streamWindow : connectionWindow;
            if (credit > 0x7fffffff - window)
                return false;
            window += credit;
            return true;
        }
        case 2:
            return frame.stream && frame.length == 5 && (read32(payload) & 0x7fffffff) != frame.stream;
        default:
            // Push is disabled. RST_STREAM, GOAWAY and unexpected stream frames fail the trial.
            return frame.type > 9;
        }
    }
    bool decodeHeaders(size_t length, bool trailers)
    {
        const uint8_t* cursor = block;
        const uint8_t* end = block + length;
        bool status = false;
        bool regular = false;
        size_t decoded = 0;
        for (unsigned count = 0; cursor < end && count < 128; ++count) {
            char scratch[8192];
            lsxpack_header header;
            lsxpack_header_prepare_decode(&header, scratch, 0, sizeof(scratch));
            const uint8_t* before = cursor;
            if (lshpack_dec_decode(&decoder, &cursor, end, &header) || cursor <= before || !header.name_len)
                return false;
            decoded += header.name_len + header.val_len;
            if (decoded > sizeof(block))
                return false;
            const char* name = lsxpack_header_get_name(&header);
            if (name[0] == ':') {
                if (trailers || regular || status || header.name_len != 7 || memcmp(name, ":status", 7)
                    || header.val_len != 3 || memcmp(lsxpack_header_get_value(&header), "200", 3))
                    return false;
                status = true;
            } else
                regular = true;
        }
        return cursor == end && (trailers || status);
    }
    bool get(const char* path, const char* expected, ColloBenchReply& reply)
    {
        size_t pathLength = strnlen(path, 2049);
        size_t expectedLength = expected ? strnlen(expected, bodyLimit + 1) : 0;
        if (!ssl || !pathLength || path[0] != '/' || pathLength > 2048 || expectedLength > bodyLimit
            || nextStream > 0x7fffffff)
            return false;
        uint8_t request[4096];
        uint8_t* end = request + 9;
        *end++ = 0x82; // Indexed GET and https from the HPACK static table.
        *end++ = 0x87;
        end = literal(end, 1, authority, strlen(authority));
        end = literal(end, 4, path, pathLength);
        reply.stream_id = nextStream;
        nextStream += 2;
        streamWindow = initialWindow;
        frameHeader(request, end - request - 9, 1, 5, reply.stream_id);
        size_t blockLength = 0;
        bool headers = false;
        bool continuation = false;
        bool endStream = false;
        ERR_clear_error();
        // The entire HEADERS frame is encoded before this first transport write.
        reply.sent_ns = monotonicNs();
        if (!reply.sent_ns || SSL_write(ssl.get(), request, static_cast<int>(end - request)) != end - request)
            return false;
        for (unsigned count = 0; count < frameCountLimit; ++count) {
            Frame frame;
            if (!readFrame(frame))
                return false;
            bool done = false;
            if (continuation && (frame.type != 9 || frame.stream != reply.stream_id))
                return false;
            if (frame.type == 1 || frame.type == 9 || frame.type == 0) {
                if (frame.stream != reply.stream_id || (frame.type == 9 && !continuation))
                    return false;
                size_t begin = 0;
                size_t finish = frame.length;
                if (frame.type != 9 && (frame.flags & 8)) {
                    if (!finish || payload[0] >= finish)
                        return false;
                    begin = 1;
                    finish -= payload[0];
                }
                if (frame.type == 1 && (frame.flags & 32)) {
                    if (finish - begin < 5 || (read32(payload + begin) & 0x7fffffff) == frame.stream)
                        return false;
                    begin += 5;
                }
                size_t length = finish - begin;
                if (frame.type == 0) {
                    if (!headers || length > (expected ? expectedLength : 4096) - reply.body_len
                        || (expected && memcmp(expected + reply.body_len, payload + begin, length)))
                        return false;
                    reply.body_len += static_cast<uint32_t>(length);
                    done = frame.flags & 1;
                    if (done)
                        reply.response_ns = monotonicNs();
                    if (frame.length) {
                        uint8_t credit[4];
                        write32(credit, static_cast<uint32_t>(frame.length));
                        if (!sendFrame(8, 0, 0, credit, 4) || (!done && !sendFrame(8, 0, frame.stream, credit, 4)))
                            return false;
                    }
                } else {
                    if (frame.type == 1) {
                        if (headers && !(frame.flags & 1))
                            return false;
                        blockLength = 0;
                        endStream = frame.flags & 1;
                    }
                    if (length > sizeof(block) - blockLength)
                        return false;
                    memcpy(block + blockLength, payload + begin, length);
                    blockLength += length;
                    continuation = !(frame.flags & 4);
                    if (continuation)
                        continue;
                    if (!decodeHeaders(blockLength, headers))
                        return false;
                    headers = true;
                    done = endStream;
                    if (done)
                        reply.response_ns = monotonicNs();
                }
            } else if (!control(frame))
                return false;
            if (done) {
                reply.status = 200;
                return headers && reply.response_ns >= reply.sent_ns && reply.response_ns
                    && (!expected || reply.body_len == expectedLength);
            }
        }
        return false;
    }
};

extern "C" int collo_bench_client_open(uint16_t port, const char* hostname, ColloBenchClient** out)
{
    if (!out)
        return -1;
    *out = nullptr;
    if (!port || !hostname || !hostname[0] || strnlen(hostname, 256) >= 256)
        return -1;
    ERR_clear_error();
    std::unique_ptr<ColloBenchClient> client(new (std::nothrow) ColloBenchClient);
    if (!client)
        return -1;
    strcpy(client->authority, hostname);
    client->fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    timeval timeout { 10, 0 };
    int noDelay = 1;
    if (client->fd < 0 || setsockopt(client->fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout))
        || setsockopt(client->fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout))
        || setsockopt(client->fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, sizeof(noDelay)))
        return -1;
    sockaddr_in address {};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(client->fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)))
        return -1;
    client->context.reset(SSL_CTX_new(TLS_client_method()));
    if (!client->context)
        return -1;
    // The endpoint is a loopback-only benchmark with a self-signed fixture certificate.
    SSL_CTX_set_verify(client->context.get(), SSL_VERIFY_NONE, nullptr);
    client->ssl.reset(SSL_new(client->context.get()));
    client->method.reset(BIO_meth_new(0, nullptr));
    if (!client->ssl || !client->method || !BIO_meth_set_write(client->method.get(), socketWrite)
        || !BIO_meth_set_read(client->method.get(), socketRead)
        || !BIO_meth_set_ctrl(client->method.get(), socketControl))
        return -1;
    BIO* bio = BIO_new(client->method.get());
    if (!bio)
        return -1;
    BIO_set_data(bio, &client->fd);
    BIO_set_init(bio, 1);
    SSL_set_bio(client->ssl.get(), bio, bio);
    const uint8_t alpn[] { 2, 'h', '2' };
    if (!SSL_set_tlsext_host_name(client->ssl.get(), hostname)
        || SSL_set_alpn_protos(client->ssl.get(), alpn, sizeof(alpn)) || SSL_connect(client->ssl.get()) != 1)
        return -1;
    const uint8_t* selected = nullptr;
    unsigned selectedLength = 0;
    SSL_get0_alpn_selected(client->ssl.get(), &selected, &selectedLength);
    if (selectedLength != 2 || memcmp(selected, "h2", 2))
        return -1;
    const char preface[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    const uint8_t settings[] { 0, 2, 0, 0, 0, 0 }; // Disable server push.
    if (!client->write(preface, sizeof(preface) - 1) || !client->sendFrame(4, 0, 0, settings, sizeof(settings)))
        return -1;
    for (unsigned count = 0; count < 64 && !(client->peerSettings && client->settingsAck); ++count) {
        ColloBenchClient::Frame frame;
        if (!client->readFrame(frame) || (!count && (frame.type != 4 || (frame.flags & 1))) || !client->control(frame))
            return -1;
    }
    ColloBenchReply health {};
    if (!client->peerSettings || !client->settingsAck || !client->get("/__collo/healthz", nullptr, health))
        return -1;
    *out = client.release();
    return 0;
}

extern "C" int collo_bench_client_get(
    ColloBenchClient* client, const char* path, const char* expected, ColloBenchReply* out)
{
    if (out)
        *out = {};
    if (!client)
        return -1;
    ColloBenchReply reply {};
    if (!out || !path || !expected || !client->get(path, expected, reply)) {
        client->disconnect();
        return -1;
    }
    *out = reply;
    return 0;
}

extern "C" void collo_bench_client_close(ColloBenchClient* client) { delete client; }
