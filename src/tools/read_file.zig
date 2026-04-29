const std = @import("std");
const mod = @import("mod.zig");

pub const tool: mod.Tool = .{
    .name = "read_file",
    .description =
    \\Read the contents of a UTF-8 text file from the local filesystem.
    \\Returns the full file contents on success, or an error message string
    \\describing what went wrong (file not found, too large, etc.) so you can
    \\adjust your approach. The file is capped at 1 MiB; larger files are
    \\truncated with a notice appended.
    ,
    .parameters_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Filesystem path to the file. Relative paths resolve against the agent's current working directory."}},"required":["path"],"additionalProperties":false}
    ,
    .execute = execute,
};

const MAX_BYTES: usize = 1 * 1024 * 1024;

fn execute(allocator: std.mem.Allocator, args_json: []const u8) anyerror![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to parse arguments JSON ({s})", .{@errorName(err)});
    };
    defer parsed.deinit();

    const path_val = parsed.value.object.get("path") orelse {
        return try allocator.dupe(u8, "error: missing required argument 'path'");
    };
    if (path_val != .string) {
        return try allocator.dupe(u8, "error: argument 'path' must be a string");
    }
    const path = path_val.string;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {s}", .{ path, @errorName(err) });
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        return std.fmt.allocPrint(allocator, "error: cannot stat '{s}': {s}", .{ path, @errorName(err) });
    };

    const read_len: usize = if (stat.size > MAX_BYTES) MAX_BYTES else @intCast(stat.size);
    const truncated = stat.size > MAX_BYTES;

    const buf = try allocator.alloc(u8, read_len);
    errdefer allocator.free(buf);
    _ = file.readAll(buf) catch |err| {
        allocator.free(buf);
        return std.fmt.allocPrint(allocator, "error: read failed for '{s}': {s}", .{ path, @errorName(err) });
    };

    if (!truncated) return buf;

    defer allocator.free(buf);
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\n[truncated: file is {d} bytes, only the first {d} bytes were returned]",
        .{ buf, stat.size, read_len },
    );
}
