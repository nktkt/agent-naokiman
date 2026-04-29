const std = @import("std");
const mod = @import("mod.zig");

pub const tool: mod.Tool = .{
    .name = "write_file",
    .description =
    \\Create a new file or overwrite an existing one with the given content.
    \\Parent directories are created automatically. The content is written
    \\verbatim — no escaping or trailing newline added. Capped at 4 MiB.
    \\
    \\WARNING: this overwrites existing files without confirmation. For
    \\modifying part of an existing file, prefer the `edit_file` tool.
    ,
    .parameters_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Filesystem path to write."},"content":{"type":"string","description":"Full content to write to the file. Include a trailing newline if you want one."}},"required":["path","content"],"additionalProperties":false}
    ,
    .execute = execute,
};

const MAX_BYTES: usize = 4 * 1024 * 1024;

fn execute(allocator: std.mem.Allocator, args_json: []const u8) anyerror![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to parse arguments JSON ({s})", .{@errorName(err)});
    };
    defer parsed.deinit();

    const path_v = parsed.value.object.get("path") orelse {
        return try allocator.dupe(u8, "error: missing required argument 'path'");
    };
    const content_v = parsed.value.object.get("content") orelse {
        return try allocator.dupe(u8, "error: missing required argument 'content'");
    };
    if (path_v != .string) return try allocator.dupe(u8, "error: 'path' must be a string");
    if (content_v != .string) return try allocator.dupe(u8, "error: 'content' must be a string");

    const path = path_v.string;
    const content = content_v.string;

    if (content.len > MAX_BYTES) {
        return std.fmt.allocPrint(
            allocator,
            "error: content too large ({d} bytes; max {d}). Use multiple write_file calls or a different approach.",
            .{ content.len, MAX_BYTES },
        );
    }

    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) {
            std.fs.cwd().makePath(dir) catch |err| {
                return std.fmt.allocPrint(
                    allocator,
                    "error: cannot create parent directory '{s}': {s}",
                    .{ dir, @errorName(err) },
                );
            };
        }
    }

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "error: cannot create '{s}': {s}",
            .{ path, @errorName(err) },
        );
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "error: write failed for '{s}': {s}",
            .{ path, @errorName(err) },
        );
    };

    return std.fmt.allocPrint(allocator, "wrote {d} bytes to {s}", .{ content.len, path });
}
