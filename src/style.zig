//! Tiny ANSI styling helpers. All `open(...)` / `close()` calls return an
//! empty slice when styling is disabled, so callsites can stay branch-free.
const std = @import("std");

var enabled_state: bool = false;

pub fn detect(stdout_is_tty: bool) void {
    if (!stdout_is_tty) {
        enabled_state = false;
        return;
    }
    // https://no-color.org — any non-empty value disables ANSI styling.
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "NO_COLOR") catch {
        enabled_state = true;
        return;
    };
    defer std.heap.page_allocator.free(home);
    enabled_state = home.len == 0;
}

pub fn force(on: bool) void {
    enabled_state = on;
}

pub fn enabled() bool {
    return enabled_state;
}

pub const reset_seq = "\x1b[0m";

// Simple foreground colors
pub const fg_red = "\x1b[31m";
pub const fg_green = "\x1b[32m";
pub const fg_yellow = "\x1b[33m";
pub const fg_blue = "\x1b[34m";
pub const fg_magenta = "\x1b[35m";
pub const fg_cyan = "\x1b[36m";
pub const fg_gray = "\x1b[90m";

// Bold + color
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const bold_red = "\x1b[1;31m";
pub const bold_green = "\x1b[1;32m";
pub const bold_yellow = "\x1b[1;33m";
pub const bold_blue = "\x1b[1;34m";
pub const bold_cyan = "\x1b[1;36m";

// Highlight (red text on yellow background)
pub const danger = "\x1b[1;37;41m";

pub fn open(code: []const u8) []const u8 {
    return if (enabled_state) code else "";
}

pub fn close() []const u8 {
    return if (enabled_state) reset_seq else "";
}
