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
pub const ChatRequestArgs = struct {
    out: *std.Io.Writer,
    model: []const u8,
    history: *const History,
    stream: bool = false,
    tools_raw_json: ?[]const u8 = null,
    /// Emitted as a top-level boolean when set. Qwen requires this for
    /// reliable multi-tool turns; other providers tolerate it.
    parallel_tool_calls: ?bool = null,
};

pub fn writeChatRequest(args: ChatRequestArgs) !void {
    var s: std.json.Stringify = .{ .writer = args.out, .options = .{} };
    try s.beginObject();

    try s.objectField("model");
    try s.write(args.model);

    try s.objectField("stream");
    try s.write(args.stream);

    try s.objectField("messages");
    try s.beginArray();
    for (args.history.items.items) |m| {
        try writeMessage(&s, m);
    }
    try s.endArray();

    if (args.tools_raw_json) |tools_json| {
        try s.objectField("tools");
        try s.beginWriteRaw();
        try args.out.writeAll(tools_json);
        s.endWriteRaw();
    }

    if (args.parallel_tool_calls) |p| {
        try s.objectField("parallel_tool_calls");
        try s.write(p);
    }

    try s.endObject();
}

/// Serialize just the messages array (no model/tools wrapper) to `out`.
/// Round-trips with `loadHistoryJson`.
pub fn writeHistoryJson(out: *std.Io.Writer, history: *const History) !void {
    var s: std.json.Stringify = .{ .writer = out, .options = .{} };
    try s.beginArray();
    for (history.items.items) |m| {
        try writeMessage(&s, m);
    }
    try s.endArray();
}

/// Replace `history.items` with messages parsed from a JSON array produced
/// by `writeHistoryJson`. Existing items are dropped.
pub fn loadHistoryJson(history: *History, body: []const u8, parent_alloc: std.mem.Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, parent_alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidFormat;

    history.clear();

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const role_v = item.object.get("role") orelse continue;
        if (role_v != .string) continue;
        const role = role_v.string;

        if (std.mem.eql(u8, role, "system")) {
            const c = item.object.get("content") orelse continue;
            if (c == .string) try history.appendSystem(c.string);
        } else if (std.mem.eql(u8, role, "user")) {
            const c = item.object.get("content") orelse continue;
            if (c == .string) try history.appendUser(c.string);
        } else if (std.mem.eql(u8, role, "assistant")) {
            const text: []const u8 = if (item.object.get("content")) |c|
                if (c == .string) c.string else ""
            else
                "";

            var tcs_buf = std.ArrayList(ToolCall){};
            defer tcs_buf.deinit(parent_alloc);

            if (item.object.get("tool_calls")) |tcs| {
                if (tcs == .array) {
                    for (tcs.array.items) |tc_v| {
                        if (tc_v != .object) continue;
                        const id_v = tc_v.object.get("id") orelse continue;
                        const fn_v = tc_v.object.get("function") orelse continue;
                        if (id_v != .string or fn_v != .object) continue;
                        const name_v = fn_v.object.get("name") orelse continue;
                        const args_v = fn_v.object.get("arguments") orelse continue;
                        if (name_v != .string) continue;
                        const args_str: []const u8 = if (args_v == .string) args_v.string else "{}";
                        try tcs_buf.append(parent_alloc, .{
                            .id = id_v.string,
                            .name = name_v.string,
                            .arguments_json = args_str,
                        });
                    }
                }
            }

            if (tcs_buf.items.len > 0) {
                try history.appendAssistantToolCalls(text, tcs_buf.items);
            } else {
                try history.appendAssistantText(text);
            }
        } else if (std.mem.eql(u8, role, "tool")) {
            const id_v = item.object.get("tool_call_id") orelse continue;
            const c_v = item.object.get("content") orelse continue;
            if (id_v != .string or c_v != .string) continue;
            try history.appendToolResult(id_v.string, c_v.string);
        }
    }
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
