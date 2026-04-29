const std = @import("std");
const mod = @import("mod.zig");

pub const tool: mod.Tool = .{
    .name = "glob",
    .description =
    \\Find files whose path matches a glob pattern. Returns one path per line.
    \\Supports:
    \\  *   matches any character except "/"
    \\  ?   matches a single character except "/"
    \\  **  matches any number of path segments (including zero)
    \\  /   path separator
    \\
    \\Examples:
    \\  src/**/*.zig    every .zig file under src, at any depth
    \\  *.md            top-level markdown files
    \\  build*          files starting with "build" in the current dir
    ,
    .parameters_schema_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern. See description for syntax."},"root":{"type":"string","description":"Directory to search from. Defaults to '.'."}},"required":["pattern"],"additionalProperties":false}
    ,
    .execute = execute,
};

const MAX_RESULTS: usize = 4096;
const MAX_OUTPUT: usize = 256 * 1024;

fn execute(allocator: std.mem.Allocator, args_json: []const u8) anyerror![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to parse arguments JSON ({s})", .{@errorName(err)});
    };
    defer parsed.deinit();

    const pattern_v = parsed.value.object.get("pattern") orelse {
        return try allocator.dupe(u8, "error: missing 'pattern'");
    };
    if (pattern_v != .string) return try allocator.dupe(u8, "error: 'pattern' must be a string");
    const pattern = pattern_v.string;

    const root: []const u8 = blk: {
        if (parsed.value.object.get("root")) |v| {
            if (v == .string and v.string.len > 0) break :blk v.string;
        }
        break :blk ".";
    };

    return walkAndMatch(allocator, root, pattern);
}

fn walkAndMatch(allocator: std.mem.Allocator, root: []const u8, pattern: []const u8) ![]u8 {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {s}", .{ root, @errorName(err) });
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch |err| {
        return std.fmt.allocPrint(allocator, "error: walk failed: {s}", .{@errorName(err)});
    };
    defer walker.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var count: usize = 0;
    while (true) {
        const maybe = walker.next() catch |err| {
            try out.writer.print("[walk error: {s}]\n", .{@errorName(err)});
            break;
        };
        const entry = maybe orelse break;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!matchGlob(pattern, entry.path)) continue;
        try out.writer.writeAll(entry.path);
        try out.writer.writeAll("\n");
        count += 1;
        if (count >= MAX_RESULTS) {
            try out.writer.print("[truncated at {d} results]\n", .{MAX_RESULTS});
            break;
        }
        if (out.writer.end >= MAX_OUTPUT) {
            try out.writer.writeAll("[truncated at output cap]\n");
            break;
        }
    }
    if (count == 0) try out.writer.writeAll("(no matches)\n");

    return out.toOwnedSlice();
}

/// Match a glob pattern against a path. The pattern uses `/` as separator.
/// `*` matches within a single segment, `**` matches across segments, `?`
/// matches a single non-`/` character. Other characters match literally.
pub fn matchGlob(pattern: []const u8, path: []const u8) bool {
    return matchInner(pattern, path);
}

fn matchInner(pattern: []const u8, path: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;
    var double_star_pi: ?usize = null;
    var double_star_si: usize = 0;

    while (si < path.len) {
        if (pi < pattern.len) {
            // ** : matches across separators
            if (pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*') {
                double_star_pi = pi + 2;
                double_star_si = si;
                pi += 2;
                // Skip a following '/'
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                continue;
            }
            if (pattern[pi] == '*') {
                star_pi = pi + 1;
                star_si = si;
                pi += 1;
                continue;
            }
            if (pattern[pi] == '?') {
                if (path[si] == '/') {
                    // ? does not match separator
                } else {
                    pi += 1;
                    si += 1;
                    continue;
                }
            } else if (pattern[pi] == path[si]) {
                pi += 1;
                si += 1;
                continue;
            }
        }
        // Mismatch: backtrack to last star or double_star
        if (star_pi) |sp| {
            if (path[star_si] != '/') {
                pi = sp;
                star_si += 1;
                si = star_si;
                continue;
            }
            // Single-star cannot cross '/', try double-star instead
            star_pi = null;
        }
        if (double_star_pi) |dsp| {
            pi = dsp;
            double_star_si += 1;
            si = double_star_si;
            continue;
        }
        return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

test "matchGlob basic" {
    try std.testing.expect(matchGlob("*.zig", "main.zig"));
    try std.testing.expect(!matchGlob("*.zig", "src/main.zig"));
    try std.testing.expect(matchGlob("src/**/*.zig", "src/main.zig"));
    try std.testing.expect(matchGlob("src/**/*.zig", "src/tools/bash.zig"));
    try std.testing.expect(matchGlob("**/*.md", "PLAN.md"));
    try std.testing.expect(matchGlob("**/*.md", "docs/sub/x.md"));
    try std.testing.expect(matchGlob("build*", "build.zig"));
    try std.testing.expect(!matchGlob("build*", "src/build.zig"));
    try std.testing.expect(matchGlob("a?c", "abc"));
    try std.testing.expect(!matchGlob("a?c", "a/c"));
}
