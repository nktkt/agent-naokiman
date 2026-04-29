const std = @import("std");
const config = @import("config.zig");
const http = @import("transport/http.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg: config.Config = undefined;
    try config.load(&cfg, allocator);
    defer cfg.deinit();

    const api_key = cfg.deepseek_api_key orelse {
        std.debug.print("error: DEEPSEEK_API_KEY not set (env or .env)\n", .{});
        return error.MissingApiKey;
    };

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const user_msg: []const u8 = if (args.len >= 2) args[1] else "Hello in one short sentence.";
    const model: []const u8 = "deepseek-chat";

    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{cfg.deepseek_base_url});
    defer allocator.free(url);

    var body_buf: std.Io.Writer.Allocating = .init(allocator);
    defer body_buf.deinit();
    try std.json.Stringify.value(.{
        .model = model,
        .messages = &[_]struct {
            role: []const u8,
            content: []const u8,
        }{
            .{ .role = "user", .content = user_msg },
        },
        .stream = false,
    }, .{}, &body_buf.writer);

    std.debug.print("→ POST {s}\n", .{url});
    std.debug.print("→ model: {s}\n", .{model});
    std.debug.print("→ user: {s}\n", .{user_msg});

    var resp = try http.postJson(allocator, .{
        .url = url,
        .json_body = body_buf.written(),
        .bearer_token = api_key,
    });
    defer resp.deinit();

    std.debug.print("← status: {d}\n", .{@intFromEnum(resp.status)});
    if (!resp.isOk()) {
        std.debug.print("← body: {s}\n", .{resp.body});
        return error.HttpError;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const choices = root.object.get("choices") orelse return error.NoChoices;
    if (choices.array.items.len == 0) return error.NoChoices;
    const first = choices.array.items[0];
    const message = first.object.get("message") orelse return error.NoMessage;
    const content = message.object.get("content") orelse return error.NoContent;

    std.debug.print("← assistant: {s}\n", .{content.string});
}
