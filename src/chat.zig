const std = @import("std");
const http = @import("transport/http.zig");
const message = @import("message.zig");
const provider = @import("provider.zig");
const interrupt = @import("interrupt.zig");

pub const Usage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
};

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
    usage: Usage = .{},
    interrupted: bool = false,

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

pub const TextDeltaFn = *const fn (bytes: []const u8) anyerror!void;

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

    /// Non-streaming `/chat/completions` request. Buffered end-to-end.
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

    /// Streaming `/chat/completions`. Text deltas are dispatched to
    /// `on_text` immediately as they arrive; tool_calls are accumulated
    /// silently. Returns the assembled `ChatResponse` at the end.
    pub fn chatStreaming(
        self: Client,
        history: *const message.History,
        tools_raw_json: ?[]const u8,
        on_text: ?TextDeltaFn,
    ) !ChatResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/chat/completions",
            .{self.base_url},
        );
        defer self.allocator.free(url);

        const parallel_tools: ?bool = if (tools_raw_json != null) true else null;

        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_buf.deinit();
        try message.writeChatRequest(.{
            .out = &body_buf.writer,
            .model = self.model,
            .history = history,
            .stream = true,
            .tools_raw_json = tools_raw_json,
            .parallel_tool_calls = parallel_tools,
            .include_usage = true,
        });

        const uri = try std.Uri.parse(url);

        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        var auth_buf: [256]u8 = undefined;
        const auth_value = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key});

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Accept", .value = "text/event-stream" },
        };

        var req = try client.request(.POST, uri, .{
            .keep_alive = false,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = &headers,
        });
        defer req.deinit();

        // sendBodyComplete needs a mutable []u8; the body content is owned by
        // body_buf and not used after the call.
        const body_mutable: []u8 = body_buf.written();
        req.transfer_encoding = .{ .content_length = body_mutable.len };
        try req.sendBodyComplete(body_mutable);

        var redirect_buf: [8 * 1024]u8 = undefined;
        var resp = try req.receiveHead(&redirect_buf);
        const status_code = @intFromEnum(resp.head.status);
        if (status_code < 200 or status_code >= 300) {
            std.debug.print("error: streaming status={d}\n", .{status_code});
            return error.HttpError;
        }

        var transfer_buf: [16 * 1024]u8 = undefined;
        const reader = resp.reader(&transfer_buf);

        return parseSseStream(self.allocator, reader, on_text);
    }
};

const ToolCallBuilder = struct {
    id: std.ArrayListUnmanaged(u8) = .empty,
    name: std.ArrayListUnmanaged(u8) = .empty,
    args: std.ArrayListUnmanaged(u8) = .empty,
};

fn parseSseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    on_text: ?TextDeltaFn,
) !ChatResponse {
    var text_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text_buf.deinit(allocator);

    var builders = std.ArrayListUnmanaged(ToolCallBuilder){};
    errdefer {
        for (builders.items) |*b| {
            b.id.deinit(allocator);
            b.name.deinit(allocator);
            b.args.deinit(allocator);
        }
        builders.deinit(allocator);
    }

    var finish: FinishReason = .other;
    var usage: Usage = .{};
    var was_interrupted = false;

    sse_loop: while (true) {
        if (interrupt.requested()) {
            was_interrupted = true;
            break :sse_loop;
        }
        const maybe_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.StreamTooLong,
            else => return err,
        };
        const raw = maybe_line orelse break :sse_loop;
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "data:")) continue;

        var data = line["data:".len..];
        if (data.len > 0 and data[0] == ' ') data = data[1..];
        if (std.mem.eql(u8, data, "[DONE]")) break :sse_loop;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;

        // Final chunk for stream_options.include_usage carries usage and an
        // empty choices array on most providers.
        if (root.object.get("usage")) |u| {
            if (u == .object) usage = parseUsage(u);
        }

        const choices = root.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const first = choices.array.items[0];
        if (first != .object) continue;

        if (first.object.get("finish_reason")) |fv| {
            if (fv == .string) finish = FinishReason.fromString(fv.string);
        }

        const delta = first.object.get("delta") orelse continue;
        if (delta != .object) continue;

        if (delta.object.get("content")) |c| {
            if (c == .string and c.string.len > 0) {
                try text_buf.appendSlice(allocator, c.string);
                if (on_text) |cb| try cb(c.string);
            }
        }

        if (delta.object.get("tool_calls")) |tcs| {
            if (tcs != .array) continue;
            for (tcs.array.items) |tc_v| {
                if (tc_v != .object) continue;
                const idx_v = tc_v.object.get("index") orelse continue;
                const idx: usize = if (idx_v == .integer) @intCast(idx_v.integer) else continue;

                while (builders.items.len <= idx) try builders.append(allocator, .{});
                var b = &builders.items[idx];

                if (tc_v.object.get("id")) |idv| {
                    if (idv == .string) try b.id.appendSlice(allocator, idv.string);
                }
                if (tc_v.object.get("function")) |fnv| {
                    if (fnv == .object) {
                        if (fnv.object.get("name")) |nv| {
                            if (nv == .string) try b.name.appendSlice(allocator, nv.string);
                        }
                        if (fnv.object.get("arguments")) |av| {
                            if (av == .string) try b.args.appendSlice(allocator, av.string);
                        }
                    }
                }
            }
        }
    }

    const text_owned = try text_buf.toOwnedSlice(allocator);
    errdefer allocator.free(text_owned);

    var tool_calls_list = std.ArrayList(message.ToolCall){};
    errdefer {
        for (tool_calls_list.items) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.arguments_json);
        }
        tool_calls_list.deinit(allocator);
    }

    for (builders.items) |*b| {
        if (b.id.items.len == 0 and b.name.items.len == 0) {
            b.id.deinit(allocator);
            b.name.deinit(allocator);
            b.args.deinit(allocator);
            continue;
        }
        const id = try b.id.toOwnedSlice(allocator);
        const name = try b.name.toOwnedSlice(allocator);
        const args = if (b.args.items.len > 0)
            try b.args.toOwnedSlice(allocator)
        else
            try allocator.dupe(u8, "{}");
        try tool_calls_list.append(allocator, .{
            .id = id,
            .name = name,
            .arguments_json = args,
        });
    }
    builders.deinit(allocator);

    if (finish == .other and tool_calls_list.items.len > 0) finish = .tool_calls;
    if (finish == .other) finish = .stop;

    return .{
        .usage = usage,
        .interrupted = was_interrupted,
        .allocator = allocator,
        .finish_reason = finish,
        .text = text_owned,
        .tool_calls = try tool_calls_list.toOwnedSlice(allocator),
    };
}

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

    var usage: Usage = .{};
    if (root.object.get("usage")) |u| {
        if (u == .object) usage = parseUsage(u);
    }

    return .{
        .allocator = allocator,
        .finish_reason = FinishReason.fromString(finish_str),
        .text = text,
        .tool_calls = try tool_calls.toOwnedSlice(allocator),
        .usage = usage,
    };
}

fn parseUsage(v: std.json.Value) Usage {
    var u: Usage = .{};
    if (v.object.get("prompt_tokens")) |x| {
        if (x == .integer) u.prompt_tokens = @intCast(x.integer);
    }
    if (v.object.get("completion_tokens")) |x| {
        if (x == .integer) u.completion_tokens = @intCast(x.integer);
    }
    if (v.object.get("total_tokens")) |x| {
        if (x == .integer) u.total_tokens = @intCast(x.integer);
    }
    return u;
}
