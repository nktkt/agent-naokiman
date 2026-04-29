const std = @import("std");
const mod = @import("mod.zig");
const diff = @import("../diff.zig");

pub const tool: mod.Tool = .{
    .name = "multi_edit",
    .description =
    \\Apply a sequence of exact-match search/replace edits to a single file
    \\atomically. Edits are applied in order — each edit's `old_string` must
    \\match the file content as it stands AFTER the previous edits in the
    \\sequence. Each match must be unique (zero or duplicate matches abort
    \\the entire batch with the file unchanged). Faster and safer than
    \\several `edit_file` calls when changing multiple regions of the same
    \\file.
    ,
    .parameters_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File to edit."},"edits":{"type":"array","minItems":1,"items":{"type":"object","properties":{"old_string":{"type":"string","description":"Substring to find. Must be unique at the time this edit is applied."},"new_string":{"type":"string","description":"Replacement (use empty string to delete)."}},"required":["old_string","new_string"],"additionalProperties":false}}},"required":["path","edits"],"additionalProperties":false}
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
    const edits_v = obj.get("edits") orelse return try allocator.dupe(u8, "error: missing 'edits'");
    if (path_v != .string) return try allocator.dupe(u8, "error: 'path' must be a string");
    if (edits_v != .array) return try allocator.dupe(u8, "error: 'edits' must be an array");
    if (edits_v.array.items.len == 0) return try allocator.dupe(u8, "error: 'edits' must not be empty");

    const path = path_v.string;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {s}", .{ path, @errorName(err) });
    };
    const stat = file.stat() catch |err| {
        file.close();
        return std.fmt.allocPrint(allocator, "error: cannot stat '{s}': {s}", .{ path, @errorName(err) });
    };
    if (stat.size > MAX_BYTES) {
        file.close();
        return std.fmt.allocPrint(allocator, "error: file too large ({d} bytes; max {d})", .{ stat.size, MAX_BYTES });
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.resize(allocator, @intCast(stat.size));
    _ = file.readAll(buf.items) catch |err| {
        file.close();
        return std.fmt.allocPrint(allocator, "error: read failed: {s}", .{@errorName(err)});
    };
    file.close();

    const original_size = buf.items.len;
    const original_copy = try allocator.dupe(u8, buf.items);
    defer allocator.free(original_copy);

    for (edits_v.array.items, 0..) |edit_v, i| {
        if (edit_v != .object) {
            return std.fmt.allocPrint(allocator, "error: edits[{d}] is not an object", .{i});
        }
        const old_v = edit_v.object.get("old_string") orelse {
            return std.fmt.allocPrint(allocator, "error: edits[{d}] missing 'old_string'", .{i});
        };
        const new_v = edit_v.object.get("new_string") orelse {
            return std.fmt.allocPrint(allocator, "error: edits[{d}] missing 'new_string'", .{i});
        };
        if (old_v != .string or new_v != .string) {
            return std.fmt.allocPrint(allocator, "error: edits[{d}] strings must be strings", .{i});
        }
        const old_s = old_v.string;
        const new_s = new_v.string;
        if (old_s.len == 0) {
            return std.fmt.allocPrint(allocator, "error: edits[{d}] 'old_string' must be non-empty", .{i});
        }

        // Count matches in current buffer.
        var match_count: usize = 0;
        var first_idx: usize = 0;
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, buf.items, search_from, old_s)) |idx| {
            if (match_count == 0) first_idx = idx;
            match_count += 1;
            search_from = idx + 1;
            if (match_count > 1) break;
        }
        if (match_count == 0) {
            return std.fmt.allocPrint(
                allocator,
                "error: edits[{d}] 'old_string' not found at this point in the buffer (file unchanged)",
                .{i},
            );
        }
        if (match_count > 1) {
            return std.fmt.allocPrint(
                allocator,
                "error: edits[{d}] 'old_string' appears more than once at this point (file unchanged)",
                .{i},
            );
        }

        // Splice: replace [first_idx, first_idx+old_s.len) with new_s.
        try buf.replaceRange(allocator, first_idx, old_s.len, new_s);
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.naokiman.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        const tmp = std.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch |err| {
            return std.fmt.allocPrint(allocator, "error: cannot create temp file '{s}': {s}", .{ tmp_path, @errorName(err) });
        };
        defer tmp.close();
        tmp.writeAll(buf.items) catch |err| {
            std.fs.cwd().deleteFile(tmp_path) catch {};
            return std.fmt.allocPrint(allocator, "error: write failed: {s}", .{@errorName(err)});
        };
        tmp.sync() catch {};
    }

    std.fs.cwd().rename(tmp_path, path) catch |err| {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        return std.fmt.allocPrint(allocator, "error: atomic rename failed: {s}", .{@errorName(err)});
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        "applied {d} edits to '{s}' ({d} -> {d} bytes)",
        .{ edits_v.array.items.len, path, original_size, buf.items.len },
    );
    try out.writer.writeAll(diff.DIFF_MARKER);
    try diff.writeBlockPlain(&out.writer, original_copy, buf.items);
    return out.toOwnedSlice();
}
