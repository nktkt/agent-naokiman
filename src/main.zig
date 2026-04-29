const std = @import("std");
const config = @import("config.zig");
const message = @import("message.zig");
const deepseek = @import("deepseek.zig");

const SYSTEM_PROMPT =
    \\You are naokiman, a concise assistant. Reply in the same language the user uses.
;

const DEFAULT_MODEL = "deepseek-chat";

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

    const client: deepseek.Client = .{
        .allocator = allocator,
        .api_key = api_key,
        .base_url = cfg.deepseek_base_url,
        .model = DEFAULT_MODEL,
    };

    if (args.len >= 2) {
        try runOneShot(allocator, client, args[1]);
    } else {
        try runRepl(allocator, client);
    }
}

fn runOneShot(allocator: std.mem.Allocator, client: deepseek.Client, prompt: []const u8) !void {
    var history = message.History.init(allocator);
    defer history.deinit();
    try history.append(.system, SYSTEM_PROMPT);
    try history.append(.user, prompt);

    const reply = try client.chat(&history);
    defer allocator.free(reply);

    try writeStdout(reply);
    try writeStdout("\n");
}

fn runRepl(allocator: std.mem.Allocator, client: deepseek.Client) !void {
    var history = message.History.init(allocator);
    defer history.deinit();
    try history.append(.system, SYSTEM_PROMPT);

    try writeStdout("naokiman REPL — model: ");
    try writeStdout(client.model);
    try writeStdout("\n");
    try writeStdout("commands: /exit  /clear  /help\n\n");

    var stdin_buf: [16 * 1024]u8 = undefined;
    var stdin_file = std.fs.File.stdin();
    var stdin_reader = stdin_file.reader(&stdin_buf);
    const r = &stdin_reader.interface;

    while (true) {
        try writeStdout("you> ");

        const maybe_line = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try writeStdout("(input too long; turn skipped)\n");
                continue;
            },
            else => return err,
        };
        const raw = maybe_line orelse {
            try writeStdout("\n");
            return;
        };
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) return;
        if (std.mem.eql(u8, line, "/clear")) {
            history.clear();
            try history.append(.system, SYSTEM_PROMPT);
            try writeStdout("(history cleared)\n");
            continue;
        }
        if (std.mem.eql(u8, line, "/help")) {
            try writeStdout("/exit  end the session\n/clear reset history\n/help  this message\n");
            continue;
        }
        if (line[0] == '/') {
            try writeStdout("(unknown command — try /help)\n");
            continue;
        }

        try history.append(.user, line);

        const reply = client.chat(&history) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            _ = history.items.pop();
            continue;
        };
        defer allocator.free(reply);

        try history.append(.assistant, reply);

        try writeStdout("naokiman> ");
        try writeStdout(reply);
        try writeStdout("\n\n");
    }
}

fn writeStdout(bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}
