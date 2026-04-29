const std = @import("std");
const config = @import("config.zig");
const message = @import("message.zig");
const chat = @import("chat.zig");
const provider = @import("provider.zig");
const tools = @import("tools/mod.zig");
const perm = @import("perm.zig");
const style = @import("style.zig");

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
const HEREDOC_DELIM = "<<<";

const CliOptions = struct {
    provider_kind: provider.Kind = .deepseek,
    model_override: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    show_help: bool = false,
    auto_approve: bool = false,
    no_stream: bool = false,
    no_color: bool = false,
    resume_session: ?[]const u8 = null,
};

const USAGE =
    \\usage: naokiman [options] [prompt]
    \\
    \\options:
    \\  --provider <name>   deepseek (default), kimi, qwen
    \\  --model <id>        override the provider's default model
    \\  --resume <name>     load a saved session before starting
    \\  -y, --yes           auto-approve all destructive tool calls
    \\  --no-stream         disable SSE streaming
    \\  --no-color          disable ANSI color output (also honors NO_COLOR=1)
    \\  -h, --help          show this help
    \\
    \\modes:
    \\  no prompt   start an interactive REPL
    \\  prompt      run a single turn (positional argument)
    \\
    \\REPL multiline input:
    \\  enter `<<<` on a line by itself to start a multiline block, then
    \\  another `<<<` line to submit it.
    \\
    \\REPL slash commands:
    \\  /exit  /clear  /help
    \\  /save <name>     save current session to ~/.config/agent-naokiman/sessions/<name>.json
    \\  /load <name>     replace history with a saved session
    \\  /sessions        list saved sessions
    \\
    \\config:
    \\  ~/.config/agent-naokiman/.env  (DEEPSEEK_API_KEY / MOONSHOT_API_KEY / DASHSCOPE_API_KEY)
    \\  ~/.config/agent-naokiman/sessions/  (saved chat histories)
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
    style.detect(std.fs.File.stdout().isTty());
    if (opts.no_color) style.force(false);

    var policy = perm.Policy.init(allocator, opts.auto_approve, interactive);
    defer policy.deinit();

    const stream_enabled = !opts.no_stream;

    var history = message.History.init(allocator);
    defer history.deinit();

    if (opts.resume_session) |name| {
        loadSession(allocator, &history, name) catch |err| {
            std.debug.print("error: cannot resume session '{s}': {s}\n", .{ name, @errorName(err) });
            return err;
        };
    } else {
        try history.appendSystem(SYSTEM_PROMPT);
    }

    if (opts.prompt) |p| {
        try runOneShot(allocator, client, tools_json, &policy, sr, stream_enabled, &history, p);
    } else {
        try runRepl(allocator, client, tools_json, &policy, sr, stream_enabled, &history);
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
        } else if (std.mem.eql(u8, a, "--no-stream")) {
            opts.no_stream = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, a, "--provider")) {
            i += 1;
            if (i >= args.len) return error.MissingProviderArg;
            opts.provider_kind = provider.Kind.fromString(args[i]) orelse return error.UnknownProvider;
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingModelArg;
            opts.model_override = args[i];
        } else if (std.mem.eql(u8, a, "--resume")) {
            i += 1;
            if (i >= args.len) return error.MissingResumeArg;
            opts.resume_session = args[i];
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
    stream_enabled: bool,
    history: *message.History,
    prompt: []const u8,
) !void {
    try history.appendUser(prompt);

    const reply = try driveAgent(allocator, client, tools_json, policy, stdin_reader, stream_enabled, history);
    if (!stream_enabled) try writeStdout(reply);
    try writeStdout("\n");
}

fn runRepl(
    allocator: std.mem.Allocator,
    client: chat.Client,
    tools_json: []const u8,
    policy: *perm.Policy,
    stdin_reader: *std.Io.Reader,
    stream_enabled: bool,
    history: *message.History,
) !void {
    try printBanner(client);

    while (true) {
        try writePrompt("you> ", style.bold_cyan);

        const first = (try readLine(stdin_reader)) orelse {
            try writeStdout("\n");
            return;
        };
        const trimmed = std.mem.trim(u8, first, " \t\r\n");
        if (trimmed.len == 0) continue;

        // Multiline heredoc
        const submitted: []const u8 = if (std.mem.eql(u8, trimmed, HEREDOC_DELIM)) blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            errdefer buf.deinit(allocator);
            heredoc: while (true) {
                try writePrompt("... ", style.dim);
                const next = (try readLine(stdin_reader)) orelse break :heredoc;
                const next_trimmed = std.mem.trimRight(u8, next, "\r");
                if (std.mem.eql(u8, std.mem.trim(u8, next_trimmed, " \t"), HEREDOC_DELIM)) break :heredoc;
                if (buf.items.len > 0) try buf.append(allocator, '\n');
                try buf.appendSlice(allocator, next_trimmed);
            }
            const owned = try buf.toOwnedSlice(allocator);
            defer allocator.free(owned);
            const dup = try allocator.dupe(u8, owned);
            break :blk dup;
        } else trimmed;

        defer if (submitted.ptr != trimmed.ptr) allocator.free(submitted);

        if (std.mem.eql(u8, submitted, "/exit") or std.mem.eql(u8, submitted, "/quit")) return;
        if (std.mem.eql(u8, submitted, "/clear")) {
            history.clear();
            try history.appendSystem(SYSTEM_PROMPT);
            try writeStdout("(history cleared)\n");
            continue;
        }
        if (std.mem.eql(u8, submitted, "/help")) {
            try writeStdout("/exit         end the session\n");
            try writeStdout("/clear        reset history\n");
            try writeStdout("/help         this message\n");
            try writeStdout("/save <name>  save the current session\n");
            try writeStdout("/load <name>  replace history with a saved session\n");
            try writeStdout("/sessions     list saved sessions\n");
            continue;
        }
        if (std.mem.eql(u8, submitted, "/sessions")) {
            try listSessions(allocator);
            continue;
        }
        if (std.mem.startsWith(u8, submitted, "/save ")) {
            const name = std.mem.trim(u8, submitted["/save ".len..], " \t");
            if (name.len == 0) {
                try writeStdout("(usage: /save <name>)\n");
                continue;
            }
            saveSession(allocator, history, name) catch |err| {
                std.debug.print("error: save failed: {s}\n", .{@errorName(err)});
                continue;
            };
            try writeStdout("(saved as '");
            try writeStdout(name);
            try writeStdout("')\n");
            continue;
        }
        if (std.mem.startsWith(u8, submitted, "/load ")) {
            const name = std.mem.trim(u8, submitted["/load ".len..], " \t");
            if (name.len == 0) {
                try writeStdout("(usage: /load <name>)\n");
                continue;
            }
            loadSession(allocator, history, name) catch |err| {
                std.debug.print("error: load failed: {s}\n", .{@errorName(err)});
                continue;
            };
            try writeStdout("(loaded '");
            try writeStdout(name);
            try writeStdout("')\n");
            continue;
        }
        if (submitted[0] == '/') {
            try writeStdout("(unknown command — try /help)\n");
            continue;
        }

        try history.appendUser(submitted);

        try writePrompt("naokiman> ", style.bold_blue);
        const reply = driveAgent(allocator, client, tools_json, policy, stdin_reader, stream_enabled, history) catch |err| {
            try writeStyledLine("error: ", @errorName(err), style.bold_red);
            continue;
        };

        if (!stream_enabled) try writeStdout(reply);
        try writeStdout("\n\n");
    }
}

fn readLine(stdin_reader: *std.Io.Reader) !?[]const u8 {
    const maybe = stdin_reader.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => {
            try writeStdout("(input too long; line skipped)\n");
            return "";
        },
        else => return err,
    };
    return maybe;
}

fn driveAgent(
    allocator: std.mem.Allocator,
    client: chat.Client,
    tools_json: []const u8,
    policy: *perm.Policy,
    stdin_reader: *std.Io.Reader,
    stream_enabled: bool,
    history: *message.History,
) ![]const u8 {
    var turn: usize = 0;
    while (turn < MAX_TURNS) : (turn += 1) {
        var resp = if (stream_enabled)
            try client.chatStreaming(history, tools_json, writeStdout)
        else
            try client.chat(history, tools_json);
        defer resp.deinit();

        if (resp.tool_calls.len == 0) {
            try history.appendAssistantText(resp.text);
            const last = history.items.items[history.items.items.len - 1];
            return last.assistant.text;
        }

        try history.appendAssistantToolCalls(resp.text, resp.tool_calls);

        for (resp.tool_calls) |tc| {
            try writeStdout(style.open(style.fg_cyan));
            try writeStdout("⟢ ");
            try writeStdout(tc.name);
            try writeStdout("(");
            try writeStdout(tc.arguments_json);
            try writeStdout(")");
            try writeStdout(style.close());
            try writeStdout("\n");

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

fn writePrompt(text: []const u8, code: []const u8) !void {
    try writeStdout(style.open(code));
    try writeStdout(text);
    try writeStdout(style.close());
}

fn writeStyledLine(prefix: []const u8, text: []const u8, code: []const u8) !void {
    try writeStdout(style.open(code));
    try writeStdout(prefix);
    try writeStdout(text);
    try writeStdout(style.close());
    try writeStdout("\n");
}

fn printBanner(client: chat.Client) !void {
    const bar = style.open(style.bold_blue);
    const accent = style.open(style.bold_cyan);
    const sub = style.open(style.fg_blue);
    const subtle = style.open(style.fg_cyan);
    const reset = style.close();

    // Line 1: title
    try writeStdout(bar);
    try writeStdout("▎ ");
    try writeStdout(reset);
    try writeStdout(accent);
    try writeStdout("naokiman");
    try writeStdout(reset);
    try writeStdout(sub);
    try writeStdout("  ·  ");
    try writeStdout(client.kind.label());
    try writeStdout("  ·  ");
    try writeStdout(client.model);
    try writeStdout(reset);
    try writeStdout("\n");

    // Line 2: slash commands
    try writeStdout(bar);
    try writeStdout("▎ ");
    try writeStdout(reset);
    try writeStdout(subtle);
    try writeStdout("/exit  /clear  /help  /save <name>  /load <name>  /sessions");
    try writeStdout(reset);
    try writeStdout("\n");

    // Line 3: multiline hint
    try writeStdout(bar);
    try writeStdout("▎ ");
    try writeStdout(reset);
    try writeStdout(subtle);
    try writeStdout("multiline: ");
    try writeStdout(accent);
    try writeStdout("<<<");
    try writeStdout(reset);
    try writeStdout(subtle);
    try writeStdout(" … ");
    try writeStdout(accent);
    try writeStdout("<<<");
    try writeStdout(reset);
    try writeStdout("\n\n");
}

fn writeStderr(bytes: []const u8) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

// --- session save / load ---------------------------------------------------

fn sessionsDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "agent-naokiman", "sessions" });
    }
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.HomeNotSet;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "agent-naokiman", "sessions" });
}

fn sessionPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidSessionName;
    if (name.len == 0) return error.InvalidSessionName;

    const dir = try sessionsDir(allocator);
    defer allocator.free(dir);
    const file = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
    defer allocator.free(file);
    return std.fs.path.join(allocator, &.{ dir, file });
}

fn saveSession(allocator: std.mem.Allocator, history: *const message.History, name: []const u8) !void {
    const path = try sessionPath(allocator, name);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try message.writeHistoryJson(&out.writer, history);

    const file = try std.fs.cwd().createFile(path, .{ .mode = 0o600, .truncate = true });
    defer file.close();
    try file.writeAll(out.writer.buffered());
}

fn loadSession(allocator: std.mem.Allocator, history: *message.History, name: []const u8) !void {
    const path = try sessionPath(allocator, name);
    defer allocator.free(path);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0 or stat.size > 16 * 1024 * 1024) return error.InvalidSessionFile;

    const body = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(body);
    _ = try file.readAll(body);

    try message.loadHistoryJson(history, body, allocator);
    if (history.items.items.len == 0 or history.items.items[0] != .system) {
        // Ensure a system prompt is at the front for sane behavior.
        const items_copy = history.items.items;
        _ = items_copy;
        try history.appendSystem(SYSTEM_PROMPT);
    }
}

fn listSessions(allocator: std.mem.Allocator) !void {
    const dir_path = try sessionsDir(allocator);
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try writeStdout("(no sessions saved yet)\n");
            return;
        },
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - ".json".len];
        try writeStdout("  ");
        try writeStdout(stem);
        try writeStdout("\n");
        count += 1;
    }
    if (count == 0) try writeStdout("(no sessions saved yet)\n");
}
