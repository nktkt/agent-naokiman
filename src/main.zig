const std = @import("std");
const config = @import("config.zig");
const message = @import("message.zig");
const chat = @import("chat.zig");
const provider = @import("provider.zig");
const tools = @import("tools/mod.zig");
const perm = @import("perm.zig");

const SYSTEM_PROMPT =
    \\You are naokiman, a concise coding assistant running in a terminal.
    \\Reply in the same language the user uses (Japanese ↔ English).
    \\
    \\You have file/shell tools available. Use them when the answer requires
    \\inspecting the local filesystem or running a command. Otherwise just
    \\answer directly. Keep replies short.
    \\
    \\Note: write_file, edit_file, and bash require the user's confirmation
    \\before each call. If the user denies a call, accept the denial and
    \\suggest a different approach rather than retrying.
;

const MAX_TURNS: usize = 20;

const CliOptions = struct {
    provider_kind: provider.Kind = .deepseek,
    model_override: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    show_help: bool = false,
    auto_approve: bool = false,
};

const USAGE =
    \\usage: naokiman [options] [prompt]
    \\
    \\options:
    \\  --provider <name>   deepseek (default), kimi, qwen
    \\  --model <id>        override the provider's default model
    \\  -y, --yes           auto-approve all destructive tool calls (bash,
    \\                      write_file, edit_file). Use only in trusted
    \\                      automated contexts.
    \\  -h, --help          show this help
    \\
    \\modes:
    \\  no prompt   start an interactive REPL
    \\  prompt      run a single turn (positional argument)
    \\
    \\config:
    \\  ~/.config/agent-naokiman/.env  (DEEPSEEK_API_KEY / MOONSHOT_API_KEY / DASHSCOPE_API_KEY)
    \\
;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const opts = parseArgs(args) catch |err| {
        try writeStderr(USAGE);
        return err;
    };

    if (opts.show_help) {
        try writeStdout(USAGE);
        return;
    }

    var cfg: config.Config = undefined;
    try config.load(&cfg, allocator);
    defer cfg.deinit();

    const sel = provider.select(&cfg, opts.provider_kind, opts.model_override) catch |err| switch (err) {
        error.MissingApiKey => {
            std.debug.print(
                "error: {s} not set (env or .env)\n",
                .{provider.missingKeyEnvName(opts.provider_kind)},
            );
            return error.MissingApiKey;
        },
    };

    const client = chat.Client.fromSelection(allocator, sel);

    const tools_json = try tools.renderToolsJson(allocator);
    defer allocator.free(tools_json);

    var stdin_buf: [16 * 1024]u8 = undefined;
    var stdin_file = std.fs.File.stdin();
    var stdin_reader = stdin_file.reader(&stdin_buf);
    const sr = &stdin_reader.interface;

    const interactive = stdin_file.isTty();
    var policy = perm.Policy.init(allocator, opts.auto_approve, interactive);
    defer policy.deinit();

    if (opts.prompt) |p| {
        try runOneShot(allocator, client, tools_json, &policy, sr, p);
    } else {
        try runRepl(allocator, client, tools_json, &policy, sr);
    }
}

fn parseArgs(args: []const [:0]u8) !CliOptions {
    var opts: CliOptions = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            opts.show_help = true;
        } else if (std.mem.eql(u8, a, "-y") or std.mem.eql(u8, a, "--yes")) {
            opts.auto_approve = true;
        } else if (std.mem.eql(u8, a, "--provider")) {
            i += 1;
            if (i >= args.len) return error.MissingProviderArg;
            opts.provider_kind = provider.Kind.fromString(args[i]) orelse return error.UnknownProvider;
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingModelArg;
            opts.model_override = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        } else {
            if (opts.prompt != null) return error.TooManyPositionalArgs;
            opts.prompt = a;
        }
    }
    return opts;
}

fn runOneShot(
    allocator: std.mem.Allocator,
    client: chat.Client,
    tools_json: []const u8,
    policy: *perm.Policy,
    stdin_reader: *std.Io.Reader,
    prompt: []const u8,
) !void {
    var history = message.History.init(allocator);
    defer history.deinit();
    try history.appendSystem(SYSTEM_PROMPT);
    try history.appendUser(prompt);

    const reply = try driveAgent(allocator, client, tools_json, policy, stdin_reader, &history);
    try writeStdout(reply);
    try writeStdout("\n");
}

fn runRepl(
    allocator: std.mem.Allocator,
    client: chat.Client,
    tools_json: []const u8,
    policy: *perm.Policy,
    stdin_reader: *std.Io.Reader,
) !void {
    var history = message.History.init(allocator);
    defer history.deinit();
    try history.appendSystem(SYSTEM_PROMPT);

    try writeStdout("naokiman REPL — provider: ");
    try writeStdout(client.kind.label());
    try writeStdout(", model: ");
    try writeStdout(client.model);
    try writeStdout("\n");
    try writeStdout("commands: /exit  /clear  /help\n\n");

    while (true) {
        try writeStdout("you> ");

        const maybe_line = stdin_reader.takeDelimiter('\n') catch |err| switch (err) {
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

        const reply = driveAgent(allocator, client, tools_json, policy, stdin_reader, &history) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
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
    client: chat.Client,
    tools_json: []const u8,
    policy: *perm.Policy,
    stdin_reader: *std.Io.Reader,
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

            const approved = try policy.approve(tc.name, tc.arguments_json, stdin_reader, writeStdout);
            if (!approved) {
                const denial =
                    "permission denied by user. The user blocked this tool call. " ++
                    "Do not retry the same call; suggest an alternative or stop.";
                try history.appendToolResult(tc.id, denial);
                continue;
            }

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
    }

    return error.MaxTurnsExceeded;
}

fn writeStdout(bytes: []const u8) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn writeStderr(bytes: []const u8) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}
