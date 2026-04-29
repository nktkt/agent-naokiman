//! Tiny diff helper. Emits a block diff (all old lines as "-", all new lines
//! as "+"). Plain text variant for tool-result strings; ANSI-colored variant
//! for terminal display.
const std = @import("std");
const style = @import("style.zig");

/// Marker that separates a tool's summary line from its appended diff.
/// Tool results that include a diff embed it after this marker so the host
/// can split it back out for styled display.
pub const DIFF_MARKER = "\n--- diff ---\n";

/// Plain (no-ANSI) block diff. Suitable for embedding in tool result text
/// that goes back to the LLM.
pub fn writeBlockPlain(out: *std.Io.Writer, old: []const u8, new: []const u8) !void {
    if (old.len > 0) {
        var it = std.mem.splitScalar(u8, old, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first or it.index != null or line.len > 0) {
                try out.writeAll("- ");
                try out.writeAll(line);
                try out.writeAll("\n");
            }
            first = false;
        }
    }
    if (new.len > 0) {
        var it = std.mem.splitScalar(u8, new, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first or it.index != null or line.len > 0) {
                try out.writeAll("+ ");
                try out.writeAll(line);
                try out.writeAll("\n");
            }
            first = false;
        }
    }
}

/// Render an existing diff block (lines starting with "- " / "+ " / "@@ ")
/// to the given writer with ANSI colors when style is enabled. If the
/// content has no markers it is passed through unchanged.
pub fn writeDiffStyled(out: *std.Io.Writer, diff: []const u8, sink: *const fn ([]const u8) anyerror!void) !void {
    _ = out;
    var it = std.mem.splitScalar(u8, diff, '\n');
    while (it.next()) |line| {
        if (line.len == 0) {
            try sink("\n");
            continue;
        }
        if (std.mem.startsWith(u8, line, "- ")) {
            try sink(style.open(style.fg_red));
            try sink(line);
            try sink(style.close());
        } else if (std.mem.startsWith(u8, line, "+ ")) {
            try sink(style.open(style.fg_green));
            try sink(line);
            try sink(style.close());
        } else if (std.mem.startsWith(u8, line, "@@ ")) {
            try sink(style.open(style.fg_cyan));
            try sink(line);
            try sink(style.close());
        } else {
            try sink(line);
        }
        try sink("\n");
    }
}
