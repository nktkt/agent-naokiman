const std = @import("std");

/// One tool invocation produced by the assistant. `arguments_json` holds the
/// raw JSON-encoded argument string exactly as the model returned it (the
/// OpenAI / DeepSeek API wraps its arguments as a stringified JSON object).
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const Message = union(enum) {
    system: []const u8,
    user: []const u8,
    assistant: AssistantMsg,
    tool: ToolMsg,

    pub const AssistantMsg = struct {
        /// Optional. May be empty when the assistant turn is a pure tool-call.
        text: []const u8 = "",
        tool_calls: []const ToolCall = &.{},
    };

    pub const ToolMsg = struct {
        tool_call_id: []const u8,
        content: []const u8,
    };
};

pub const History = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayListUnmanaged(Message) = .empty,

    pub fn init(parent: std.mem.Allocator) History {
        return .{ .arena = std.heap.ArenaAllocator.init(parent) };
    }

    pub fn deinit(self: *History) void {
        self.arena.deinit();
    }

    pub fn clear(self: *History) void {
        _ = self.arena.reset(.retain_capacity);
        self.items = .empty;
    }

    pub fn appendSystem(self: *History, text: []const u8) !void {
        const a = self.arena.allocator();
        try self.items.append(a, .{ .system = try a.dupe(u8, text) });
    }

    pub fn appendUser(self: *History, text: []const u8) !void {
        const a = self.arena.allocator();
        try self.items.append(a, .{ .user = try a.dupe(u8, text) });
    }

    pub fn appendAssistantText(self: *History, text: []const u8) !void {
        const a = self.arena.allocator();
        try self.items.append(a, .{ .assistant = .{ .text = try a.dupe(u8, text) } });
    }

    /// Tool calls and their fields are deep-copied into the arena so callers
    /// can free their own copies after appending.
    pub fn appendAssistantToolCalls(
        self: *History,
        text: []const u8,
        tool_calls: []const ToolCall,
    ) !void {
        const a = self.arena.allocator();
        const owned_text = try a.dupe(u8, text);
        const owned_calls = try a.alloc(ToolCall, tool_calls.len);
        for (tool_calls, 0..) |tc, i| {
            owned_calls[i] = .{
                .id = try a.dupe(u8, tc.id),
                .name = try a.dupe(u8, tc.name),
                .arguments_json = try a.dupe(u8, tc.arguments_json),
            };
        }
        try self.items.append(a, .{
            .assistant = .{ .text = owned_text, .tool_calls = owned_calls },
        });
    }

    pub fn appendToolResult(self: *History, tool_call_id: []const u8, content: []const u8) !void {
        const a = self.arena.allocator();
        try self.items.append(a, .{ .tool = .{
            .tool_call_id = try a.dupe(u8, tool_call_id),
            .content = try a.dupe(u8, content),
        } });
    }
};

/// Serialize a History (and optional tools array) into a JSON body suitable
/// for OpenAI-compatible /chat/completions endpoints.
///
/// `tools_raw_json` should be either `null` (no tools) or a complete JSON
/// array string like `[{"type":"function","function":{...}}, ...]` — it is
/// written verbatim into the body. This avoids re-serializing static schema
/// definitions on every request.
pub fn writeChatRequest(
    out: *std.Io.Writer,
    model: []const u8,
    history: *const History,
    stream: bool,
    tools_raw_json: ?[]const u8,
) !void {
    var s: std.json.Stringify = .{ .writer = out, .options = .{} };
    try s.beginObject();

    try s.objectField("model");
    try s.write(model);

    try s.objectField("stream");
    try s.write(stream);

    try s.objectField("messages");
    try s.beginArray();
    for (history.items.items) |m| {
        try writeMessage(&s, m);
    }
    try s.endArray();

    if (tools_raw_json) |tools_json| {
        try s.objectField("tools");
        try s.beginWriteRaw();
        try out.writeAll(tools_json);
        s.endWriteRaw();
    }

    try s.endObject();
}

fn writeMessage(s: *std.json.Stringify, m: Message) !void {
    try s.beginObject();
    switch (m) {
        .system => |text| {
            try s.objectField("role");
            try s.write("system");
            try s.objectField("content");
            try s.write(text);
        },
        .user => |text| {
            try s.objectField("role");
            try s.write("user");
            try s.objectField("content");
            try s.write(text);
        },
        .assistant => |a| {
            try s.objectField("role");
            try s.write("assistant");
            try s.objectField("content");
            try s.write(a.text);
            if (a.tool_calls.len > 0) {
                try s.objectField("tool_calls");
                try s.beginArray();
                for (a.tool_calls) |tc| {
                    try s.beginObject();
                    try s.objectField("id");
                    try s.write(tc.id);
                    try s.objectField("type");
                    try s.write("function");
                    try s.objectField("function");
                    try s.beginObject();
                    try s.objectField("name");
                    try s.write(tc.name);
                    try s.objectField("arguments");
                    try s.write(tc.arguments_json);
                    try s.endObject();
                    try s.endObject();
                }
                try s.endArray();
            }
        },
        .tool => |t| {
            try s.objectField("role");
            try s.write("tool");
            try s.objectField("tool_call_id");
            try s.write(t.tool_call_id);
            try s.objectField("content");
            try s.write(t.content);
        },
    }
    try s.endObject();
}
