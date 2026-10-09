//! Assertions over an `ingress.lane.CounterSnapshot`: the transport counters
//! an HTTP/2 request raises. Not a suite of its own; `runner_contract.zig`
//! imports it.

const std = @import("std");
const ingress = @import("collo_server_main").ingress;

pub fn expectHttp2TransportObserved(self: ingress.lane.CounterSnapshot) !void {
    try std.testing.expect(self.h2_server_protocol_time_ns > 0);
    try std.testing.expect(self.ingress_channels_started > 0);
}
