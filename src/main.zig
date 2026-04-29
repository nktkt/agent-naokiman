const std = @import("std");
const config = @import("config.zig");
const message = @import("message.zig");
const deepseek = @import("deepseek.zig");
const tools = @import("tools/mod.zig");

const SYSTEM_PROMPT =
    \\You are naokiman, a concise coding assistant running in a terminal.
    \\Reply in the same language the user uses (Japanese ↔ English).
    \\
    \\You have tools available:
    \\  - read_file(path): read a UTF-8 text file
    \\  - bash(command): run a shell command via /bin/sh -c
    \\
    \\Use them when the answer requires inspecting the local filesystem or
    \\running a command. Otherwise just answer directly. Keep replies short.
;

const DEFAULT_MODEL = "deepseek-chat";
const MAX_TURNS: usize = 20;

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

    const tools_json = try tools.renderToolsJson(allocator);
    defer allocator.free(tools_json);

    if (args.len >= 2) {
        try runOneShot(allocator, client, tools_json, args[1]);
    } else {
        try runRepl(allocator, client, tools_json);
    }
}

fn runOneShot(
    allocator: std.mem.Allocator,
    client: deepseek.Client,
    tools_json: []const u8,
    prompt: []const u8,
) !void {
    var history = message.History.init(allocator);
    defer history.deinit();
    try history.appendSystem(SYSTEM_PROMPT);
    try history.appendUser(prompt);

    const reply = try driveAgent(allocator, client, tools_json, &history);
    try writeStdout(reply);
    try writeStdout("\n");
}

fn runRepl(
    allocator: std.mem.Allocator,
    client: deepseek.Client,
    tools_json: []const u8,
) !void {
    var history = message.History.init(allocator);
    defer history.deinit();
    try history.appendSystem(SYSTEM_PROMPT);

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
            try history.appendSystem(SYSTEM_PROMPT);
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

        try history.appendUser(line);

        const reply = driveAgent(allocator, client, tools_json, &history) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            // Keep history intact; the user can retry or /clear.
            continue;
        };

        try writeStdout("naokiman> ");
        try writeStdout(reply);
        try writeStdout("\n\n");
    }
}

/// Drives the tool-use loop until the model returns a stop. Appends every
/// assistant turn (text and tool_calls) and every tool result to `history`,
/// so callers can resume the conversation. Returns a slice into the history
/// (the final assistant text), valid until the history is mutated again.
fn driveAgent(
    allocator: std.mem.Allocator,
    client: deepseek.Client,
    tools_json: []const u8,
    history: *message.History,
) ![]const u8 {
    var turn: usize = 0;
    while (turn < MAX_TURNS) : (turn += 1) {
        var resp = try client.chat(history, tools_json);
        defer resp.deinit();

        if (resp.tool_calls.len == 0) {
            try history.appendAssistantText(resp.text);
            const last = history.items.items[history.items.items.len - 1];
            return last.assistant.text;
        }

        try history.appendAssistantToolCalls(resp.text, resp.tool_calls);

        for (resp.tool_calls) |tc| {
            try writeStdout("[tool] ");
            try writeStdout(tc.name);
            try writeStdout("(");
            try writeStdout(tc.arguments_json);
            try writeStdout(")\n");

            const result_text = blk: {
                if (tools.find(tc.name)) |t| {
                    break :blk t.execute(allocator, tc.arguments_json) catch |err| {
                        break :blk std.fmt.allocPrint(
                            allocator,
                            "error: tool '{s}' failed: {s}",
                            .{ tc.name, @errorName(err) },
                        ) catch return error.OutOfMemory;
                    };
                }
                break :blk std.fmt.allocPrint(
                    allocator,
                    "error: unknown tool '{s}'",
                    .{tc.name},
                ) catch return error.OutOfMemory;
            };
            defer allocator.free(result_text);

            try history.appendToolResult(tc.id, result_text);
        }

        if (resp.finish_reason != .tool_calls) {
            // Some providers return finish_reason=stop alongside tool_calls
            // when no further reply is expected. We still loop once more so
            // the assistant can summarize the tool result.
        }
    }

    return error.MaxTurnsExceeded;
}

fn writeStdout(bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}
