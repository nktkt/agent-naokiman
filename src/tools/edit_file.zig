const std = @import("std");
const mod = @import("mod.zig");

pub const tool: mod.Tool = .{
    .name = "edit_file",
    .description =
    \\Edit a text file by replacing an exact substring (`old_string`) with a
    \\new substring (`new_string`). The match must be unique — if the old
    \\string appears zero or more than once the edit is refused so you can
    \\add more surrounding context to make it unique. Preserves all other
    \\file content byte-for-byte.
    ,
    .parameters_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to edit."},"old_string":{"type":"string","description":"Exact substring to replace. Must match exactly once in the file."},"new_string":{"type":"string","description":"Replacement substring. Use the empty string to delete `old_string`."}},"required":["path","old_string","new_string"],"additionalProperties":false}
    ,
    .execute = execute,
};

const MAX_BYTES: usize = 4 * 1024 * 1024;

fn execute(allocator: std.mem.Allocator, args_json: []const u8) anyerror![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to parse arguments JSON ({s})", .{@errorName(err)});
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const path_v = obj.get("path") orelse return try allocator.dupe(u8, "error: missing 'path'");
    const old_v = obj.get("old_string") orelse return try allocator.dupe(u8, "error: missing 'old_string'");
    const new_v = obj.get("new_string") orelse return try allocator.dupe(u8, "error: missing 'new_string'");
    if (path_v != .string or old_v != .string or new_v != .string) {
        return try allocator.dupe(u8, "error: 'path', 'old_string', 'new_string' must all be strings");
    }
    const path = path_v.string;
    const old_s = old_v.string;
    const new_s = new_v.string;

    if (old_s.len == 0) {
        return try allocator.dupe(u8, "error: 'old_string' must not be empty (use write_file to create new files)");
    }

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {s}", .{ path, @errorName(err) });
    };
    const stat = file.stat() catch |err| {
        file.close();
        return std.fmt.allocPrint(allocator, "error: cannot stat '{s}': {s}", .{ path, @errorName(err) });
    };
    if (stat.size > MAX_BYTES) {
        file.close();
        return std.fmt.allocPrint(
            allocator,
            "error: file too large ({d} bytes; max {d})",
            .{ stat.size, MAX_BYTES },
        );
    }

    const orig = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(orig);
    _ = file.readAll(orig) catch |err| {
        file.close();
        return std.fmt.allocPrint(allocator, "error: read failed: {s}", .{@errorName(err)});
    };
    file.close();

    var match_count: usize = 0;
    var first_idx: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, orig, search_from, old_s)) |i| {
        if (match_count == 0) first_idx = i;
        match_count += 1;
        search_from = i + 1;
        if (match_count > 1) break;
    }
    if (match_count == 0) {
        return std.fmt.allocPrint(
            allocator,
            "error: 'old_string' not found in '{s}'. Add more surrounding context if the string is short.",
            .{path},
        );
    }
    if (match_count > 1) {
        return std.fmt.allocPrint(
            allocator,
            "error: 'old_string' appears more than once in '{s}'. Add more surrounding context to make the match unique.",
            .{path},
        );
    }

    if (std.mem.eql(u8, old_s, new_s)) {
        return std.fmt.allocPrint(allocator, "no change: 'old_string' equals 'new_string' in '{s}'", .{path});
    }

    const before = orig[0..first_idx];
    const after = orig[first_idx + old_s.len ..];

    // Atomic write: stage to a sibling .tmp file and rename, so a partial
    // failure cannot leave the target file truncated.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.naokiman.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        const tmp = std.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch |err| {
            return std.fmt.allocPrint(
                allocator,
                "error: cannot create temp file '{s}': {s}",
                .{ tmp_path, @errorName(err) },
            );
        };
        defer tmp.close();
        tmp.writeAll(before) catch |err| {
            std.fs.cwd().deleteFile(tmp_path) catch {};
            return std.fmt.allocPrint(allocator, "error: write failed: {s}", .{@errorName(err)});
        };
        tmp.writeAll(new_s) catch |err| {
            std.fs.cwd().deleteFile(tmp_path) catch {};
            return std.fmt.allocPrint(allocator, "error: write failed: {s}", .{@errorName(err)});
        };
        tmp.writeAll(after) catch |err| {
            std.fs.cwd().deleteFile(tmp_path) catch {};
            return std.fmt.allocPrint(allocator, "error: write failed: {s}", .{@errorName(err)});
        };
        tmp.sync() catch {};
    }

    std.fs.cwd().rename(tmp_path, path) catch |err| {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        return std.fmt.allocPrint(allocator, "error: atomic rename failed: {s}", .{@errorName(err)});
    };

    const new_size = before.len + new_s.len + after.len;
    return std.fmt.allocPrint(
        allocator,
        "edited '{s}': replaced 1 occurrence ({d} -> {d} bytes)",
        .{ path, orig.len, new_size },
    );
}
