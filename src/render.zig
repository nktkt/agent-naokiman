//! Stream-friendly markdown-lite renderer. Buffers a single line at a time
//! and applies inline coloring for code spans, bold, and code fences. Falls
//! back to passthrough when ANSI styling is disabled.
const std = @import("std");
const style = @import("style.zig");

pub const WriteFn = *const fn (bytes: []const u8) anyerror!void;

pub const Renderer = struct {
    enabled: bool = true,
    in_fence: bool = false,
    line: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Renderer, gpa: std.mem.Allocator) void {
        self.line.deinit(gpa);
    }

    pub fn reset(self: *Renderer, gpa: std.mem.Allocator) void {
        self.line.deinit(gpa);
        self.line = .empty;
        self.in_fence = false;
    }

    pub fn write(self: *Renderer, gpa: std.mem.Allocator, bytes: []const u8, sink: WriteFn) !void {
        if (!self.enabled or !style.enabled()) {
            return sink(bytes);
        }
        for (bytes) |c| {
            if (c == '\n') {
                try self.flushLine(sink);
                try sink("\n");
            } else {
                try self.line.append(gpa, c);
            }
        }
    }

    /// Emit any pending partial line. Call between turns or before
    /// printing other output that must not be styled by the renderer.
    pub fn flushFinal(self: *Renderer, gpa: std.mem.Allocator, sink: WriteFn) !void {
        if (self.line.items.len > 0) {
            try self.flushLine(sink);
            self.line.clearRetainingCapacity();
            _ = gpa;
        }
    }

    fn flushLine(self: *Renderer, sink: WriteFn) !void {
        const line = self.line.items;
        defer self.line.clearRetainingCapacity();

        // Code fence delimiter: lines starting with ```
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "```")) {
            self.in_fence = !self.in_fence;
            try sink(style.open(style.fg_gray));
            try sink(line);
            try sink(style.close());
            return;
        }
        if (self.in_fence) {
            try sink(style.open(style.fg_cyan));
            try sink(line);
            try sink(style.close());
            return;
        }

        // Headers
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "# ")) {
            try sink(style.open(style.bold_cyan));
            try sink(line);
            try sink(style.close());
            return;
        }
        if (std.mem.startsWith(u8, trimmed, "## ") or std.mem.startsWith(u8, trimmed, "### ")) {
            try sink(style.open(style.bold));
            try sink(line);
            try sink(style.close());
            return;
        }

        // Inline `code` and **bold**
        try renderInline(line, sink);
    }
};

fn renderInline(line: []const u8, sink: WriteFn) !void {
    var i: usize = 0;
    var plain_start: usize = 0;
    while (i < line.len) {
        // Inline code: `...`
        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                if (i > plain_start) try sink(line[plain_start..i]);
                try sink(style.open(style.fg_cyan));
                try sink(line[i .. end + 1]);
                try sink(style.close());
                i = end + 1;
                plain_start = i;
                continue;
            }
        }
        // Bold: **...**
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |end| {
                if (i > plain_start) try sink(line[plain_start..i]);
                try sink(style.open(style.bold));
                try sink(line[i .. end + 2]);
                try sink(style.close());
                i = end + 2;
                plain_start = i;
                continue;
            }
        }
        i += 1;
    }
    if (plain_start < line.len) try sink(line[plain_start..]);
}
