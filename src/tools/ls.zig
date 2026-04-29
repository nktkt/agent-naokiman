const std = @import("std");
const mod = @import("mod.zig");

pub const tool: mod.Tool = .{
    .name = "ls",
    .description =
    \\List the immediate entries of a directory. Directories are marked with
    \\a trailing "/". Hidden entries (starting with ".") are included.
    ,
    .parameters_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Directory path to list. Defaults to '.' (the current working directory)."}},"additionalProperties":false}
    ,
    .execute = execute,
};

fn execute(allocator: std.mem.Allocator, args_json: []const u8) anyerror![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to parse arguments JSON ({s})", .{@errorName(err)});
    };
    defer parsed.deinit();

    const path: []const u8 = blk: {
        if (parsed.value.object.get("path")) |v| {
            if (v == .string and v.string.len > 0) break :blk v.string;
        }
        break :blk ".";
    };

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {s}", .{ path, @errorName(err) });
    };
    defer dir.close();

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.print("{s}/\n", .{path});

    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        const slash: []const u8 = if (entry.kind == .directory) "/" else "";
        try out.writer.print("  {s}{s}  ({s})\n", .{ entry.name, slash, @tagName(entry.kind) });
        count += 1;
    }
    if (count == 0) {
        try out.writer.writeAll("  (empty)\n");
    } else {
        try out.writer.print("({d} entries)\n", .{count});
    }

    return out.toOwnedSlice();
}
