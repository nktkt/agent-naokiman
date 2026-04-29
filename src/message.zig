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
    user: UserMsg,
    assistant: AssistantMsg,
    tool: ToolMsg,

    pub const UserMsg = struct {
        text: []const u8,
        /// Each entry is a data URL (`data:image/png;base64,…`) or external
        /// http(s) URL. Empty for normal text-only turns.
        images: []const []const u8 = &.{},
    };

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
        try self.items.append(a, .{ .user = .{ .text = try a.dupe(u8, text) } });
    }

    /// Like `appendUser` but with attached image data URLs.
    pub fn appendUserMultimodal(self: *History, text: []const u8, images: []const []const u8) !void {
        const a = self.arena.allocator();
        const owned_text = try a.dupe(u8, text);
        const owned_images = try a.alloc([]const u8, images.len);
        for (images, 0..) |img, i| owned_images[i] = try a.dupe(u8, img);
        try self.items.append(a, .{ .user = .{ .text = owned_text, .images = owned_images } });
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
    /// When true, emits `stream_options: { include_usage: true }` so the
    /// final SSE chunk carries the usage block. No effect on non-streaming.
    include_usage: bool = false,
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

    if (args.stream and args.include_usage) {
        try s.objectField("stream_options");
        try s.beginObject();
        try s.objectField("include_usage");
        try s.write(true);
        try s.endObject();
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
            if (c == .string) {
                try history.appendUser(c.string);
            } else if (c == .array) {
                var text_buf: std.ArrayList(u8) = .empty;
                defer text_buf.deinit(parent_alloc);
                var imgs: std.ArrayList([]const u8) = .empty;
                defer imgs.deinit(parent_alloc);
                for (c.array.items) |part| {
                    if (part != .object) continue;
                    const t_v = part.object.get("type") orelse continue;
                    if (t_v != .string) continue;
                    if (std.mem.eql(u8, t_v.string, "text")) {
                        if (part.object.get("text")) |tx| {
                            if (tx == .string) try text_buf.appendSlice(parent_alloc, tx.string);
                        }
                    } else if (std.mem.eql(u8, t_v.string, "image_url")) {
                        if (part.object.get("image_url")) |iv| {
                            if (iv == .object) {
                                if (iv.object.get("url")) |u| {
                                    if (u == .string) try imgs.append(parent_alloc, u.string);
                                }
                            }
                        }
                    }
                }
                try history.appendUserMultimodal(text_buf.items, imgs.items);
            }
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
        .user => |u| {
            try s.objectField("role");
            try s.write("user");
            try s.objectField("content");
            if (u.images.len == 0) {
                try s.write(u.text);
            } else {
                try s.beginArray();
                if (u.text.len > 0) {
                    try s.beginObject();
                    try s.objectField("type");
                    try s.write("text");
                    try s.objectField("text");
                    try s.write(u.text);
                    try s.endObject();
                }
                for (u.images) |img_url| {
                    try s.beginObject();
                    try s.objectField("type");
                    try s.write("image_url");
                    try s.objectField("image_url");
                    try s.beginObject();
                    try s.objectField("url");
                    try s.write(img_url);
                    try s.endObject();
                    try s.endObject();
                }
                try s.endArray();
            }
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
