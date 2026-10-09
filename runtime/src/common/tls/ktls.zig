//! Linux kernel TLS: installing on a TCP socket the keys of a handshake done
//! in user space, reading records through the kernel, and following TLS 1.3
//! KeyUpdate. Once keys are installed the kernel encrypts and decrypts on the
//! socket, so application data moves with plain reads and writes, and only
//! control records need the helpers here. Nothing here keeps global state; a
//! socket and its `RekeyState` belong to one thread at a time.

const std = @import("std");
const cmsg = @import("collo_os").cmsg;

const linux = std.os.linux;

pub const Direction = enum {
    rx,
    tx,

    fn optname(self: Direction) u32 {
        return switch (self) {
            .rx => tls_rx,
            .tx => tls_tx,
        };
    }
};

pub const RecordType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
};

pub const KeyUpdateRequest = enum(u8) {
    update_not_requested = 0,
    update_requested = 1,
};

pub const CryptoInfo = struct {
    rx: DirectionCryptoInfo,
    tx: DirectionCryptoInfo,
};

pub const DirectionCryptoInfo = union(enum) {
    aes_gcm_128: TlsAesGcm128,
    aes_gcm_256: TlsAesGcm256,
    chacha20_poly1305: TlsChacha20Poly1305,
};

pub const TlsAesGcm128 = struct {
    version: u16,
    iv: [8]u8,
    key: [16]u8,
    salt: [4]u8,
    rec_seq: [8]u8,
};

pub const TlsAesGcm256 = struct {
    version: u16,
    iv: [8]u8,
    key: [32]u8,
    salt: [4]u8,
    rec_seq: [8]u8,
};

pub const TlsChacha20Poly1305 = struct {
    version: u16,
    iv: [12]u8,
    key: [32]u8,
    rec_seq: [8]u8,
};

/// TLS 1.3 traffic secrets, kept after the handshake so the kernel's keys can
/// follow a KeyUpdate. They stay with their connection, in the process that
/// terminates it, and never cross to another process. They are not
/// certificate keys, and a leak does not expose earlier sessions, but a copy
/// read from process memory, swap or a core dump exposes the connection's
/// live and recent traffic. Keep each copy no longer than its connection, and
/// call `zero` on it.
pub const RekeyState = extern struct {
    enabled_flag: u8,
    _reserved0: u8,
    tls_version: u16,
    cipher_id: u32,
    cipher_type: u16,
    secret_len: u16,
    read_generation: u64,
    write_generation: u64,
    read_secret: [max_tls13_secret_len]u8,
    write_secret: [max_tls13_secret_len]u8,
    _reserved1: [16]u8,

    pub fn disabled() RekeyState {
        return std.mem.zeroes(RekeyState);
    }

    pub fn initTls13(cipher_id: u32, read_secret: []const u8, write_secret: []const u8) !RekeyState {
        const cipher_type = try tls13KernelCipherType(cipher_id);
        const expected_secret_len = try tls13SecretLen(cipher_id);
        if (read_secret.len != expected_secret_len or write_secret.len != expected_secret_len)
            return error.InvalidTrafficSecretLength;

        var state = RekeyState.disabled();
        state.enabled_flag = 1;
        state.tls_version = tls_1_3_version;
        state.cipher_id = cipher_id;
        state.cipher_type = cipher_type;
        state.secret_len = @intCast(expected_secret_len);
        @memcpy(state.read_secret[0..read_secret.len], read_secret);
        @memcpy(state.write_secret[0..write_secret.len], write_secret);
        return state;
    }

    pub fn enabled(self: RekeyState) bool {
        return self.enabled_flag == 1;
    }

    pub fn validate(self: RekeyState) !void {
        if (self.enabled_flag == 0) {
            const disabled_state = RekeyState.disabled();
            if (!std.mem.eql(u8, std.mem.asBytes(&self), std.mem.asBytes(&disabled_state)))
                return error.InvalidKtlsRekeyState;
            return;
        }
        if (self.enabled_flag != 1)
            return error.InvalidKtlsRekeyState;
        if (self._reserved0 != 0)
            return error.InvalidKtlsRekeyState;
        for (self._reserved1) |value| {
            if (value != 0)
                return error.InvalidKtlsRekeyState;
        }
        if (self.tls_version != tls_1_3_version)
            return error.UnsupportedTlsVersion;
        const expected_secret_len = try tls13SecretLen(self.cipher_id);
        if (self.secret_len != expected_secret_len)
            return error.InvalidTrafficSecretLength;
        if (self.cipher_type != try tls13KernelCipherType(self.cipher_id))
            return error.UnsupportedTlsCipher;
        const secret_len: usize = @intCast(self.secret_len);
        if (!allZero(self.read_secret[secret_len..]))
            return error.InvalidKtlsRekeyState;
        if (!allZero(self.write_secret[secret_len..]))
            return error.InvalidKtlsRekeyState;
    }

    pub fn zero(self: *RekeyState) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
        self.* = RekeyState.disabled();
    }
};

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0)
            return false;
    }
    return true;
}

pub const InitialState = struct {
    crypto_info: CryptoInfo,
    rekey_state: RekeyState = RekeyState.disabled(),
};

/// Attaches the TLS ULP to `fd` and installs both directions' keys. On error
/// the socket may be left half configured, and Linux can neither detach the
/// ULP nor remove installed keys, so the caller must close `fd` without using
/// it again.
pub fn enableKernelRxTx(fd: std.posix.fd_t, info: CryptoInfo) !void {
    if (std.debug.runtime_safety)
        std.debug.assert(!tlsUlpAlreadyAttached(fd));
    try attachTlsUlp(fd);
    try setKernelCryptoInfo(fd, tls_rx, info.rx);
    try setKernelCryptoInfo(fd, tls_tx, info.tx);
}

/// Derives the next traffic secret for `direction` and installs its key on
/// `fd` with record sequence number zero, where RFC 8446 section 5.3 starts
/// the sequence under every new key; the kernel uses the `rec_seq` it is
/// given. Commits the secret to `state` only once the kernel has accepted
/// the key.
pub fn installUpdatedTrafficKey(fd: std.posix.fd_t, direction: Direction, state: *RekeyState) !void {
    try state.validate();
    var next_secret: [max_tls13_secret_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &next_secret);

    const secret_len = @as(usize, state.secret_len);
    var next = try deriveNextDirectionCrypto(direction, state, next_secret[0..secret_len]);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&next));
    try setKernelCryptoInfo(fd, direction.optname(), next);
    commitDirectionSecret(direction, state, next_secret[0..secret_len]);
}

/// Reads application data into `buffer`, handling any control records that
/// arrive before it. Returns 0 at end of stream.
pub fn readApplicationData(fd: std.posix.fd_t, buffer: []u8, state: *RekeyState) !usize {
    while (true) {
        var recv_msg: RecvMsg = .{};
        const read_len = try recvRecord(fd, &recv_msg, buffer);
        if (read_len == 0)
            return 0;
        const record_type = try recv_msg.recordType() orelse .application_data;
        if (record_type == .application_data)
            return read_len;
        try handleControlRecord(fd, record_type, buffer[0..read_len], state);
    }
}

/// Handles a control record the kernel delivered through recvmsg ancillary
/// data. Only a TLS 1.3 KeyUpdate is handled: a disabled `state`, as on
/// TLS 1.2, fails with `error.UnexpectedTlsControlRecord`, and an alert,
/// close_notify included, fails with `error.UnsupportedTlsControlRecord`.
/// When the peer requests an update, this answers with its own KeyUpdate
/// and rotates the send key too.
pub fn handleControlRecord(fd: std.posix.fd_t, record_type: RecordType, bytes: []const u8, state: *RekeyState) !void {
    if (!state.enabled())
        return error.UnexpectedTlsControlRecord;
    if (record_type != .handshake)
        return error.UnsupportedTlsControlRecord;

    const request = try parseKeyUpdate(bytes);
    try installUpdatedTrafficKey(fd, .rx, state);
    state.read_generation +%= 1;
    if (request == .update_requested) {
        try sendKeyUpdate(fd, .update_not_requested);
        try installUpdatedTrafficKey(fd, .tx, state);
        state.write_generation +%= 1;
    }
}

/// recvmsg state with room for the record-type control message the kernel
/// attaches to every read. One read returns records of a single type, and
/// the kernel fails the read of a record that is not application data with
/// EIO when the message does not fit.
pub const RecvMsg = struct {
    iov: [1]std.posix.iovec = undefined,
    control: [recv_control_len]u8 align(header_align) = undefined,
    msg: std.posix.msghdr = undefined,

    pub fn prepare(self: *RecvMsg, buffer: []u8) *std.posix.msghdr {
        @memset(&self.control, 0);
        self.iov[0] = .{
            .base = buffer.ptr,
            .len = buffer.len,
        };
        self.msg = .{
            .name = null,
            .namelen = 0,
            .iov = &self.iov,
            .iovlen = self.iov.len,
            .control = &self.control,
            .controllen = self.control.len,
            .flags = 0,
        };
        return &self.msg;
    }

    /// The record type the kernel attached, or null when it attached none,
    /// which means application data.
    pub fn recordType(self: *const RecvMsg) !?RecordType {
        if ((self.msg.flags & std.posix.MSG.TRUNC) != 0)
            return error.TruncatedMessage;
        if ((self.msg.flags & std.posix.MSG.CTRUNC) != 0)
            return error.TruncatedControlMessage;
        if (self.msg.controllen < @sizeOf(cmsg.Cmsghdr))
            return null;

        const header: *const cmsg.Cmsghdr = @ptrCast(@alignCast(self.control[0..].ptr));
        if (header.level != sol_tls or header.type != tls_get_record_type)
            return null;
        if (header.len < cmsg.len(1))
            return error.InvalidControlMessage;
        const raw = self.control[cmsg.dataOffset()];
        return switch (raw) {
            @intFromEnum(RecordType.change_cipher_spec) => .change_cipher_spec,
            @intFromEnum(RecordType.alert) => .alert,
            @intFromEnum(RecordType.handshake) => .handshake,
            @intFromEnum(RecordType.application_data) => .application_data,
            else => error.InvalidTlsRecordType,
        };
    }
};

/// Queues a recvmsg of `fd` on `io`. `recv_msg` and `buffer` must stay alive
/// until it completes.
pub fn queueRecvMsg(io: anytype, request_id: u64, fd: std.posix.fd_t, recv_msg: *RecvMsg, buffer: []u8) !void {
    try io.queueRecvMsg(request_id, fd, recv_msg.prepare(buffer));
}

fn recvRecord(fd: std.posix.fd_t, recv_msg: *RecvMsg, buffer: []u8) !usize {
    const msg = recv_msg.prepare(buffer);
    return recvmsgCompat(fd, msg, 0);
}

fn sendKeyUpdate(fd: std.posix.fd_t, request: KeyUpdateRequest) !void {
    const payload = [_]u8{ 24, 0, 0, 1, @intFromEnum(request) };
    var control: [send_control_len]u8 align(header_align) = std.mem.zeroes([send_control_len]u8);
    const header: *cmsg.Cmsghdr = @ptrCast(@alignCast(control[0..].ptr));
    header.* = .{
        .len = cmsg.len(1),
        .level = sol_tls,
        .type = tls_set_record_type,
    };
    control[cmsg.dataOffset()] = @intFromEnum(RecordType.handshake);

    const iov = [1]std.posix.iovec_const{
        .{
            .base = &payload,
            .len = payload.len,
        },
    };
    const msg = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const written = try sendmsgCompat(fd, &msg, std.posix.MSG.NOSIGNAL);
    if (written != payload.len)
        return error.ShortWrite;
}

/// Accepts exactly one KeyUpdate handshake message, type 24 with a one-byte
/// body (RFC 8446 §4.6.3).
pub fn parseKeyUpdate(bytes: []const u8) !KeyUpdateRequest {
    if (bytes.len != 5)
        return error.InvalidKeyUpdate;
    if (bytes[0] != 24 or bytes[1] != 0 or bytes[2] != 0 or bytes[3] != 1)
        return error.InvalidKeyUpdate;
    return switch (bytes[4]) {
        @intFromEnum(KeyUpdateRequest.update_not_requested) => .update_not_requested,
        @intFromEnum(KeyUpdateRequest.update_requested) => .update_requested,
        else => error.InvalidKeyUpdate,
    };
}

fn deriveNextDirectionCrypto(direction: Direction, state: *const RekeyState, next_secret: []u8) !DirectionCryptoInfo {
    const secret_len = @as(usize, state.secret_len);
    if (next_secret.len != secret_len)
        return error.InvalidTrafficSecretLength;

    const active_secret = switch (direction) {
        .rx => state.read_secret[0..secret_len],
        .tx => state.write_secret[0..secret_len],
    };
    try tls13ExpandLabel(state.cipher_id, next_secret, active_secret, "traffic upd");
    return try deriveDirectionCrypto(state.cipher_id, state.tls_version, next_secret, first_record_sequence);
}

/// The record sequence number of the first record under a new key
/// (RFC 8446 section 5.3).
const first_record_sequence: [8]u8 = @splat(0);

fn commitDirectionSecret(direction: Direction, state: *RekeyState, next_secret: []const u8) void {
    switch (direction) {
        .rx => @memcpy(state.read_secret[0..next_secret.len], next_secret),
        .tx => @memcpy(state.write_secret[0..next_secret.len], next_secret),
    }
}

/// Derives one direction's key and IV from a TLS 1.3 traffic secret (RFC 8446
/// §7.3). For AES-GCM the IV is split into the salt and the explicit IV the
/// kernel's layout expects.
pub fn deriveDirectionCrypto(cipher_id: u32, version: u16, traffic_secret: []const u8, rec_seq: [8]u8) !DirectionCryptoInfo {
    var key: [32]u8 = undefined;
    var iv: [12]u8 = undefined;
    defer {
        std.crypto.secureZero(u8, &key);
        std.crypto.secureZero(u8, &iv);
    }

    const key_len = try tls13KeyLen(cipher_id);
    const secret_len = try tls13SecretLen(cipher_id);
    if (traffic_secret.len != secret_len)
        return error.InvalidTrafficSecretLength;
    try tls13ExpandLabel(cipher_id, key[0..key_len], traffic_secret, "key");
    try tls13ExpandLabel(cipher_id, &iv, traffic_secret, "iv");

    return switch (cipher_id) {
        tls13_aes_128_gcm_sha256 => .{ .aes_gcm_128 = .{
            .version = version,
            .iv = iv[4..12].*,
            .key = key[0..16].*,
            .salt = iv[0..4].*,
            .rec_seq = rec_seq,
        } },
        tls13_aes_256_gcm_sha384 => .{ .aes_gcm_256 = .{
            .version = version,
            .iv = iv[4..12].*,
            .key = key,
            .salt = iv[0..4].*,
            .rec_seq = rec_seq,
        } },
        tls13_chacha20_poly1305_sha256 => .{ .chacha20_poly1305 = .{
            .version = version,
            .iv = iv,
            .key = key,
            .rec_seq = rec_seq,
        } },
        else => error.UnsupportedTlsCipher,
    };
}

fn tls13ExpandLabel(cipher_id: u32, out: []u8, secret: []const u8, label: []const u8) !void {
    var hkdf_label: [64]u8 = undefined;
    const info = try buildTls13HkdfLabel(&hkdf_label, out.len, label);

    switch (cipher_id) {
        tls13_aes_128_gcm_sha256, tls13_chacha20_poly1305_sha256 => {
            if (secret.len != 32)
                return error.InvalidTrafficSecretLength;
            const kdf = std.crypto.kdf.hkdf.HkdfSha256;
            var prk: [kdf.prk_length]u8 = undefined;
            @memcpy(&prk, secret);
            defer std.crypto.secureZero(u8, &prk);
            kdf.expand(out, info, prk);
        },
        tls13_aes_256_gcm_sha384 => {
            if (secret.len != 48)
                return error.InvalidTrafficSecretLength;
            const kdf = std.crypto.kdf.hkdf.Hkdf(std.crypto.auth.hmac.sha2.HmacSha384);
            var prk: [kdf.prk_length]u8 = undefined;
            @memcpy(&prk, secret);
            defer std.crypto.secureZero(u8, &prk);
            kdf.expand(out, info, prk);
        },
        else => return error.UnsupportedTlsCipher,
    }
}

fn buildTls13HkdfLabel(buffer: []u8, out_len: usize, label: []const u8) ![]const u8 {
    const prefix = "tls13 ";
    if (out_len > std.math.maxInt(u16) or prefix.len + label.len > std.math.maxInt(u8))
        return error.InvalidHkdfLabel;
    const total_len = 2 + 1 + prefix.len + label.len + 1;
    if (buffer.len < total_len)
        return error.InvalidHkdfLabel;

    std.mem.writeInt(u16, buffer[0..2], @intCast(out_len), .big);
    buffer[2] = @intCast(prefix.len + label.len);
    @memcpy(buffer[3..][0..prefix.len], prefix);
    @memcpy(buffer[3 + prefix.len ..][0..label.len], label);
    buffer[3 + prefix.len + label.len] = 0;
    return buffer[0..total_len];
}

fn tls13KernelCipherType(cipher_id: u32) !u16 {
    return switch (cipher_id) {
        tls13_aes_128_gcm_sha256 => tls_cipher_aes_gcm_128,
        tls13_aes_256_gcm_sha384 => tls_cipher_aes_gcm_256,
        tls13_chacha20_poly1305_sha256 => tls_cipher_chacha20_poly1305,
        else => error.UnsupportedTlsCipher,
    };
}

fn tls13KeyLen(cipher_id: u32) !usize {
    return switch (cipher_id) {
        tls13_aes_128_gcm_sha256 => 16,
        tls13_aes_256_gcm_sha384, tls13_chacha20_poly1305_sha256 => 32,
        else => error.UnsupportedTlsCipher,
    };
}

fn tls13SecretLen(cipher_id: u32) !usize {
    return switch (cipher_id) {
        tls13_aes_128_gcm_sha256, tls13_chacha20_poly1305_sha256 => 32,
        tls13_aes_256_gcm_sha384 => 48,
        else => error.UnsupportedTlsCipher,
    };
}

fn setKernelCryptoInfo(fd: std.posix.fd_t, optname: u32, info: DirectionCryptoInfo) !void {
    switch (info) {
        .aes_gcm_128 => |aes| {
            var kernel = KernelTls12CryptoInfoAesGcm128{
                .info = .{
                    .version = aes.version,
                    .cipher_type = tls_cipher_aes_gcm_128,
                },
                .iv = aes.iv,
                .key = aes.key,
                .salt = aes.salt,
                .rec_seq = aes.rec_seq,
            };
            try setTlsDirection(fd, optname, std.mem.asBytes(&kernel));
        },
        .aes_gcm_256 => |aes| {
            var kernel = KernelTls12CryptoInfoAesGcm256{
                .info = .{
                    .version = aes.version,
                    .cipher_type = tls_cipher_aes_gcm_256,
                },
                .iv = aes.iv,
                .key = aes.key,
                .salt = aes.salt,
                .rec_seq = aes.rec_seq,
            };
            try setTlsDirection(fd, optname, std.mem.asBytes(&kernel));
        },
        .chacha20_poly1305 => |chacha| {
            var kernel = KernelTls12CryptoInfoChacha20Poly1305{
                .info = .{
                    .version = chacha.version,
                    .cipher_type = tls_cipher_chacha20_poly1305,
                },
                .iv = chacha.iv,
                .key = chacha.key,
                .salt = .{},
                .rec_seq = chacha.rec_seq,
            };
            try setTlsDirection(fd, optname, std.mem.asBytes(&kernel));
        },
    }
}

fn attachTlsUlp(fd: std.posix.fd_t) !void {
    while (true) {
        const value = "tls";
        const rc = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, tcp_ulp, value.ptr, @intCast(value.len));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .BADF, .NOTSOCK => return error.InvalidHandle,
            .NOENT, .NOPROTOOPT, .NODEV, .OPNOTSUPP => return error.OperationNotSupported,
            .INVAL => return error.InvalidProtocolOption,
            else => return error.Unexpected,
        }
    }
}

fn tlsUlpAlreadyAttached(fd: std.posix.fd_t) bool {
    var name: [32]u8 = undefined;
    @memset(&name, 0);
    var name_len: std.c.socklen_t = @intCast(name.len);
    const rc = std.c.getsockopt(fd, std.posix.IPPROTO.TCP, tcp_ulp, &name, &name_len);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => name_len != 0 and name[0] != 0,
        else => false,
    };
}

fn setTlsDirection(fd: std.posix.fd_t, optname: u32, bytes: []const u8) !void {
    while (true) {
        const rc = linux.setsockopt(fd, sol_tls, optname, bytes.ptr, @intCast(bytes.len));
        switch (linux.E.init(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .BADF, .NOTSOCK => return error.InvalidHandle,
            // Linux reports ENOENT when the requested kTLS cipher/provider is
            // not available even though the TLS ULP itself exists.
            .NOENT, .NOPROTOOPT, .NODEV, .OPNOTSUPP => return error.OperationNotSupported,
            .INVAL => return error.InvalidKernelCryptoInfo,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

fn recvmsgCompat(fd: std.posix.fd_t, msg: *std.posix.msghdr, flags: u32) !usize {
    while (true) {
        const rc = std.c.recvmsg(fd, msg, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.InvalidHandle,
            .CONNRESET, .CONNREFUSED, .PIPE, .NOTCONN, .TIMEDOUT => return error.PeerClosed,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTSOCK => return error.InvalidHandle,
            .KEYEXPIRED => return error.KtlsKeyExpired,
            // The kernel may return errnos not listed here, so the rest map to
            // an error and never to `unreachable`.
            else => return error.Unexpected,
        }
    }
}

fn sendmsgCompat(fd: std.posix.fd_t, msg: *const std.posix.msghdr_const, flags: u32) !usize {
    while (true) {
        const rc = std.c.sendmsg(fd, msg, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .BADF, .NOTSOCK => return error.InvalidHandle,
            .CONNRESET, .CONNREFUSED, .PIPE, .NOTCONN, .TIMEDOUT => return error.PeerClosed,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            // The kernel may return errnos not listed here, so the rest map to
            // an error and never to `unreachable`.
            else => return error.Unexpected,
        }
    }
}

/// The kernel's `struct tls_crypto_info` and, below, its
/// `struct tls12_crypto_info_*` layouts, which TLS 1.3 uses too despite the
/// name.
pub const KernelTlsCryptoInfo = extern struct {
    version: u16,
    cipher_type: u16,
};

pub const KernelTls12CryptoInfoAesGcm128 = extern struct {
    info: KernelTlsCryptoInfo,
    iv: [8]u8,
    key: [16]u8,
    salt: [4]u8,
    rec_seq: [8]u8,
};

pub const KernelTls12CryptoInfoAesGcm256 = extern struct {
    info: KernelTlsCryptoInfo,
    iv: [8]u8,
    key: [32]u8,
    salt: [4]u8,
    rec_seq: [8]u8,
};

pub const KernelTls12CryptoInfoChacha20Poly1305 = extern struct {
    info: KernelTlsCryptoInfo,
    iv: [12]u8,
    key: [32]u8,
    salt: [0]u8,
    rec_seq: [8]u8,
};

pub const tls_1_2_version: u16 = 0x0303;
pub const tls_1_3_version: u16 = 0x0304;
pub const tls_cipher_aes_gcm_128: u16 = 51;
pub const tls_cipher_aes_gcm_256: u16 = 52;
pub const tls_cipher_chacha20_poly1305: u16 = 54;
pub const tls12_ecdhe_rsa_aes_128_gcm_sha256: u32 = 0xc02f;
pub const tls12_ecdhe_ecdsa_aes_128_gcm_sha256: u32 = 0xc02b;
pub const tls12_ecdhe_rsa_aes_256_gcm_sha384: u32 = 0xc030;
pub const tls12_ecdhe_ecdsa_aes_256_gcm_sha384: u32 = 0xc02c;
pub const tls13_aes_128_gcm_sha256: u32 = 0x1301;
pub const tls13_aes_256_gcm_sha384: u32 = 0x1302;
pub const tls13_chacha20_poly1305_sha256: u32 = 0x1303;
pub const max_tls13_secret_len: usize = 64;

const tcp_ulp: u32 = 31;
const sol_tls: i32 = 282;
const tls_tx: u32 = 1;
const tls_rx: u32 = 2;
const tls_set_record_type: c_int = 1;
const tls_get_record_type: c_int = 2;

pub const header_align = cmsg.header_align;
pub const recv_control_len = cmsg.space(1);
const send_control_len = cmsg.space(1);
