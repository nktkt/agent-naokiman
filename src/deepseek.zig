const std = @import("std");
const http = @import("transport/http.zig");
const message = @import("message.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,

    pub const ChatError = error{
        HttpError,
        InvalidResponse,
    } || std.mem.Allocator.Error || std.fmt.AllocPrintError;

    /// Send the current history to /chat/completions and return the assistant
    /// message text. Caller owns the returned slice.
    pub fn chat(self: Client, history: *const message.History) ![]u8 {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/chat/completions",
            .{self.base_url},
        );
        defer self.allocator.free(url);

        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_buf.deinit();
        try message.writeChatRequest(&body_buf.writer, self.model, history, false);

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

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            resp.body,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value;
        const choices = root.object.get("choices") orelse return error.InvalidResponse;
        if (choices.array.items.len == 0) return error.InvalidResponse;
        const first = choices.array.items[0];
        const msg_obj = first.object.get("message") orelse return error.InvalidResponse;
        const content = msg_obj.object.get("content") orelse return error.InvalidResponse;
        if (content != .string) return error.InvalidResponse;

        return try self.allocator.dupe(u8, content.string);
    }
};
