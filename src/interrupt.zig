//! Cooperative SIGINT (Ctrl+C) handling. Long-running operations periodically
//! check `requested()` and unwind gracefully; the handler itself just sets a
//! flag so it stays async-signal-safe.
const std = @import("std");
const posix = std.posix;

var flag: std.atomic.Value(bool) = .{ .raw = false };

fn handler(sig: i32) callconv(.c) void {
    _ = sig;
    flag.store(true, .release);
}

pub fn install() void {
    var act: posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
}

pub fn requested() bool {
    return flag.load(.acquire);
}

pub fn clear() void {
    flag.store(false, .release);
}
