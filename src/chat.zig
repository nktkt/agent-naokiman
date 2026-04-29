const std = @import("std");
const http = @import("transport/http.zig");
const message = @import("message.zig");
const provider = @import("provider.zig");

pub const FinishReason = enum {
    stop,
    tool_calls,
    length,
    other,

    pub fn fromString(s: []const u8) FinishReason {
        if (std.mem.eql(u8, s, "stop")) return .stop;
        if (std.mem.eql(u8, s, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, s, "length")) return .length;
        return .other;
    }
};

/// One chat completion response. Owns its allocations; call `deinit`.
pub const ChatResponse = struct {
    allocator: std.mem.Allocator,
    finish_reason: FinishReason,
    text: []u8,
    tool_calls: []message.ToolCall,

    pub fn deinit(self: *ChatResponse) void {
        self.allocator.free(self.text);
        for (self.tool_calls) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            self.allocator.free(tc.arguments_json);
        }
        self.allocator.free(self.tool_calls);
        self.* = undefined;
    }
};

/// Generic OpenAI-compatible chat client. Used for DeepSeek, Moonshot Kimi
/// and Alibaba Qwen — they all expose `/chat/completions` with the same
/// request/response shape, with minor per-provider quirks that are handled
/// via the `kind` field.
pub const Client = struct {
    allocator: std.mem.Allocator,
    kind: provider.Kind,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,

    pub fn fromSelection(allocator: std.mem.Allocator, sel: provider.Selection) Client {
        return .{
            .allocator = allocator,
            .kind = sel.kind,
            .api_key = sel.api_key,
            .base_url = sel.base_url,
            .model = sel.model,
        };
    }

    /// Send the current history (with optional tool definitions) to
    /// /chat/completions. The caller is responsible for evolving the history
    /// based on the returned `ChatResponse`.
    pub fn chat(
        self: Client,
        history: *const message.History,
        tools_raw_json: ?[]const u8,
    ) !ChatResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/chat/completions",
            .{self.base_url},
        );
        defer self.allocator.free(url);

        // Qwen recommends parallel_tool_calls=true; DeepSeek and Kimi
        // tolerate it. Only emit when tools are present.
        const parallel_tools: ?bool = if (tools_raw_json != null) true else null;

        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_buf.deinit();
        try message.writeChatRequest(.{
            .out = &body_buf.writer,
            .model = self.model,
            .history = history,
            .stream = false,
            .tools_raw_json = tools_raw_json,
            .parallel_tool_calls = parallel_tools,
        });

        var resp = try http.postJson(self.allocator, .{
            .url = url,
            .json_body = body_buf.written(),
            .bearer_token = self.api_key,
        });
        defer resp.deinit();

        if (!resp.isOk()) {
            std.debug.print("error: status={d} body={s}\n", .{
                @intFromEnum(resp.status), resp.body,
            });
            return error.HttpError;
        }

        return parseChatResponse(self.allocator, resp.body);
    }
};

fn parseChatResponse(allocator: std.mem.Allocator, body: []const u8) !ChatResponse {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const choices = root.object.get("choices") orelse return error.InvalidResponse;
    if (choices.array.items.len == 0) return error.InvalidResponse;
    const first = choices.array.items[0];

    const finish_str = if (first.object.get("finish_reason")) |fv|
        if (fv == .string) fv.string else "other"
    else
        "other";

    const msg_obj = first.object.get("message") orelse return error.InvalidResponse;

    var text: []u8 = &.{};
    if (msg_obj.object.get("content")) |c| {
        if (c == .string) text = try allocator.dupe(u8, c.string);
    }
    errdefer allocator.free(text);

    var tool_calls = std.ArrayList(message.ToolCall){};
    errdefer {
        for (tool_calls.items) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.arguments_json);
        }
        tool_calls.deinit(allocator);
    }

    if (msg_obj.object.get("tool_calls")) |tc_val| {
        if (tc_val == .array) {
            for (tc_val.array.items) |item| {
                if (item != .object) continue;
                const id_v = item.object.get("id") orelse continue;
                const fn_v = item.object.get("function") orelse continue;
                if (id_v != .string or fn_v != .object) continue;
                const name_v = fn_v.object.get("name") orelse continue;
                const args_v = fn_v.object.get("arguments") orelse continue;
                if (name_v != .string) continue;
                const args_str: []const u8 = if (args_v == .string) args_v.string else "{}";

                try tool_calls.append(allocator, .{
                    .id = try allocator.dupe(u8, id_v.string),
                    .name = try allocator.dupe(u8, name_v.string),
                    .arguments_json = try allocator.dupe(u8, args_str),
                });
            }
        }
    }

    return .{
        .allocator = allocator,
        .finish_reason = FinishReason.fromString(finish_str),
        .text = text,
        .tool_calls = try tool_calls.toOwnedSlice(allocator),
    };
}
