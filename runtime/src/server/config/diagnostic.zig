//! The message that explains why loading a configuration, or building the
//! routes from it, failed. Constructors return one error value per failure
//! class and write the specifics here: the file, the key path or the module,
//! and what was wrong with it. The caller owns the `Diagnostic`, usually on
//! its stack, and prints `message()` once; formatting never allocates, and a
//! message longer than the buffer is cut and ends in "...".

const std = @import("std");

pub const Diagnostic = struct {
    bytes: [message_bytes_max]u8 = undefined,
    len: usize = 0,

    pub const message_bytes_max: usize = 1024;
    const truncation_mark = "...";

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Replaces the message.
    pub fn set(self: *Diagnostic, comptime format: []const u8, args: anytype) void {
        var writer: std.Io.Writer = .fixed(&self.bytes);
        writer.print(format, args) catch |err| switch (err) {
            // The fixed writer fails only when the buffer is full.
            error.WriteFailed => {
                @memcpy(self.bytes[self.bytes.len - truncation_mark.len ..], truncation_mark);
                self.len = self.bytes.len;
                return;
            },
        };
        self.len = writer.end;
    }
};
