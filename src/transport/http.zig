const std = @import("std");

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }

    pub fn isOk(self: Response) bool {
        const code = @intFromEnum(self.status);
        return code >= 200 and code < 300;
    }
};

pub const PostOptions = struct {
    url: []const u8,
    json_body: []const u8,
    bearer_token: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
};

pub fn postJson(allocator: std.mem.Allocator, opts: PostOptions) !Response {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var auth_buf: [256]u8 = undefined;
    const auth_value: ?[]const u8 = if (opts.bearer_token) |tok|
        try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{tok})
    else
        null;

    var headers_list = std.ArrayList(std.http.Header){};
    defer headers_list.deinit(allocator);
    if (auth_value) |v| try headers_list.append(allocator, .{ .name = "Authorization", .value = v });
    for (opts.extra_headers) |h| try headers_list.append(allocator, h);

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer body_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = opts.url },
        .method = .POST,
        .payload = opts.json_body,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = headers_list.items,
        .response_writer = &body_writer.writer,
    });

    const owned = try body_writer.toOwnedSlice();
    return .{
        .status = result.status,
        .body = owned,
        .allocator = allocator,
    };
}
