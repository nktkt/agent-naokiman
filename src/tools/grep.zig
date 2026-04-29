const std = @import("std");
const mod = @import("mod.zig");
const glob = @import("glob.zig");

pub const tool: mod.Tool = .{
    .name = "grep",
    .description =
    \\Recursively search for a literal substring inside text files. Returns
    \\matching lines as `path:line:content`. Optionally restrict the search
    \\to files matching a glob pattern.
    ,
    .parameters_schema_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Literal substring to search for. Not a regular expression."},"root":{"type":"string","description":"Directory to search under. Defaults to '.'."},"include":{"type":"string","description":"Optional glob (e.g. '**/*.zig') to restrict which files are searched."}},"required":["pattern"],"additionalProperties":false}
    ,
    .execute = execute,
};

const MAX_FILE_BYTES: usize = 2 * 1024 * 1024;
const MAX_OUTPUT: usize = 256 * 1024;
const MAX_MATCHES: usize = 4096;

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
    if (pattern.len == 0) return try allocator.dupe(u8, "error: 'pattern' must not be empty");

    const root: []const u8 = blk: {
        if (parsed.value.object.get("root")) |v| {
            if (v == .string and v.string.len > 0) break :blk v.string;
        }
        break :blk ".";
    };

    const include_pattern: ?[]const u8 = blk: {
        if (parsed.value.object.get("include")) |v| {
            if (v == .string and v.string.len > 0) break :blk v.string;
        }
        break :blk null;
    };

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

    var match_count: usize = 0;
    var truncated = false;
    walker_loop: while (true) {
        const maybe = walker.next() catch |err| {
            try out.writer.print("[walk error: {s}]\n", .{@errorName(err)});
            break;
        };
        const entry = maybe orelse break;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (include_pattern) |inc| {
            if (!glob.matchGlob(inc, entry.path)) continue;
        }

        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();

        const stat = file.stat() catch continue;
        if (stat.size == 0 or stat.size > MAX_FILE_BYTES) continue;

        const buf = allocator.alloc(u8, @intCast(stat.size)) catch continue;
        defer allocator.free(buf);
        const n = file.readAll(buf) catch continue;
        const data = buf[0..n];

        var line_no: usize = 1;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            if (data[i] != '\n') continue;
            const line = data[line_start..i];
            if (std.mem.indexOf(u8, line, pattern) != null) {
                try out.writer.print("{s}:{d}:{s}\n", .{ entry.path, line_no, line });
                match_count += 1;
                if (match_count >= MAX_MATCHES or out.writer.end >= MAX_OUTPUT) {
                    truncated = true;
                    break :walker_loop;
                }
            }
            line_no += 1;
            line_start = i + 1;
        }
        if (line_start < data.len) {
            const line = data[line_start..data.len];
            if (std.mem.indexOf(u8, line, pattern) != null) {
                try out.writer.print("{s}:{d}:{s}\n", .{ entry.path, line_no, line });
                match_count += 1;
                if (match_count >= MAX_MATCHES or out.writer.end >= MAX_OUTPUT) {
                    truncated = true;
                    break :walker_loop;
                }
            }
        }
    }

    if (match_count == 0) {
        try out.writer.writeAll("(no matches)\n");
    } else if (truncated) {
        try out.writer.print("[truncated; {d}+ matches shown]\n", .{match_count});
    } else {
        try out.writer.print("({d} matches)\n", .{match_count});
    }

    return out.toOwnedSlice();
}
