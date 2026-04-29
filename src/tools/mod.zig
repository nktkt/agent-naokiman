const std = @import("std");

pub const read_file = @import("read_file.zig");
pub const bash = @import("bash.zig");

pub const ExecuteFn = *const fn (allocator: std.mem.Allocator, args_json: []const u8) anyerror![]u8;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema describing the function arguments.
    parameters_schema_json: []const u8,
    /// Returns a heap-allocated string describing the result. Caller owns it.
    /// Errors should be reported in-band as a string when possible (so the
    /// LLM can see them); only return errors from the function for genuine
    /// allocator / unrecoverable failures.
    execute: ExecuteFn,
};

pub const all: []const Tool = &.{
    read_file.tool,
    bash.tool,
};

pub fn find(name: []const u8) ?Tool {
    for (all) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Build the OpenAI-compatible `tools` array payload as a single JSON string.
/// Format: `[{"type":"function","function":{"name":...,"description":...,"parameters":{...}}}, ...]`
pub fn renderToolsJson(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try s.beginArray();
    for (all) |t| {
        try s.beginObject();
        try s.objectField("type");
        try s.write("function");
        try s.objectField("function");
        try s.beginObject();
        try s.objectField("name");
        try s.write(t.name);
        try s.objectField("description");
        try s.write(t.description);
        try s.objectField("parameters");
        try s.beginWriteRaw();
        try out.writer.writeAll(t.parameters_schema_json);
        s.endWriteRaw();
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();

    return out.toOwnedSlice();
}
