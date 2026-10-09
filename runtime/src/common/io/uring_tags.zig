//! The top byte of io_uring user_data that each tagged completion producer
//! owns. A decoder recognizes its completions by that byte and rejects the
//! rest, so producers that can complete on the same ring need different
//! bytes; with a shared byte, one would decode the other's completions as its
//! own. Every tagged producer declares its byte here and lists it in
//! `high_byte_tags`, because the comptime check below sees only listed
//! bytes; it fails the build on a duplicate tag or on a tag inside the
//! listener-accept range.

pub const high_byte_shift: u6 = 56;
pub const high_nibble_shift: u6 = 60;

pub const shared_supervision_high_byte: u64 = 0xc0;
pub const server_ingress_high_byte: u64 = 0xce;
pub const worker_scheduler_high_byte: u64 = 0x57;
pub const egress_high_byte: u64 = 0x53;
pub const egress_gateway_readiness_high_byte: u64 = 0x54;

/// A range of top bytes, every byte whose high nibble is this one, that no
/// tag may fall in.
pub const listener_accept_top_nibble: u64 = 0xA;
pub const listener_accept_high_byte_min: u64 = listener_accept_top_nibble << 4;
pub const listener_accept_high_byte_max: u64 = listener_accept_high_byte_min | 0xF;

pub const high_byte_tags = [_]u64{
    shared_supervision_high_byte,
    server_ingress_high_byte,
    worker_scheduler_high_byte,
    egress_high_byte,
    egress_gateway_readiness_high_byte,
};

pub fn isListenerAcceptHighByteReserved(tag: u64) bool {
    return tag >= listener_accept_high_byte_min and tag <= listener_accept_high_byte_max;
}

pub fn highByteTagsAreUnique() bool {
    for (high_byte_tags, 0..) |tag, index| {
        for (high_byte_tags[index + 1 ..]) |other| {
            if (tag == other)
                return false;
        }
    }
    return true;
}

fn validateRegistry() void {
    inline for (high_byte_tags, 0..) |tag, index| {
        if (tag > 0xff)
            @compileError("io_uring high-byte tag must fit in 8 bits");
        if (isListenerAcceptHighByteReserved(tag))
            @compileError("io_uring high-byte tag collides with listener accept 0xA* range");
        inline for (high_byte_tags, 0..) |other, other_index| {
            if (index != other_index and tag == other)
                @compileError("duplicate io_uring high-byte user_data tag");
        }
    }
}

comptime {
    validateRegistry();
}
