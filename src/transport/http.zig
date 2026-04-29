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

const MAX_RETRIES: usize = 3;
const INITIAL_BACKOFF_NS: u64 = 250 * std.time.ns_per_ms;

/// POST a JSON body. Retries up to `MAX_RETRIES` times on connection-class
/// errors and 5xx responses, with exponential backoff (250ms, 500ms, 1s, ...).
/// 4xx is returned without retry — the caller's request body is wrong, so
/// repeating won't help.
pub fn postJson(allocator: std.mem.Allocator, opts: PostOptions) !Response {
    var attempt: usize = 0;
    var backoff: u64 = INITIAL_BACKOFF_NS;
    while (true) : (attempt += 1) {
        if (postJsonOnce(allocator, opts)) |resp| {
            const code = @intFromEnum(resp.status);
            if (code >= 500 and code < 600 and attempt < MAX_RETRIES) {
                std.debug.print(
                    "warning: http {d} (attempt {d}/{d}); retrying in {d}ms\n",
                    .{ code, attempt + 1, MAX_RETRIES, backoff / std.time.ns_per_ms },
                );
                var mut = resp;
                mut.deinit();
                std.Thread.sleep(backoff);
                backoff *= 2;
                continue;
            }
            return resp;
        } else |err| {
            if (!shouldRetry(err)) return err;
            if (attempt >= MAX_RETRIES) return err;
            std.debug.print(
                "warning: {s} (attempt {d}/{d}); retrying in {d}ms\n",
                .{ @errorName(err), attempt + 1, MAX_RETRIES, backoff / std.time.ns_per_ms },
            );
            std.Thread.sleep(backoff);
            backoff *= 2;
        }
    }
}

fn shouldRetry(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.UnknownHostName,
        error.WouldBlock,
        error.EndOfStream,
        error.TlsInitializationFailed,
        => true,
        else => false,
    };
}

fn postJsonOnce(allocator: std.mem.Allocator, opts: PostOptions) !Response {
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
