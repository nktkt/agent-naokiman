const std = @import("std");
const config = @import("config.zig");
const message = @import("message.zig");
const chat = @import("chat.zig");
const provider = @import("provider.zig");
const tools = @import("tools/mod.zig");
const perm = @import("perm.zig");
const style = @import("style.zig");
const interrupt = @import("interrupt.zig");
const render = @import("render.zig");
const mcp = @import("mcp.zig");

fn installSigintHandler() void {
    interrupt.install();
}

// Global so the streaming TextDeltaFn pointer can reach it without changing
// the chat.zig callback signature. CLI is single-threaded.
var g_renderer: render.Renderer = .{};
var g_render_alloc: std.mem.Allocator = undefined;

fn streamSink(bytes: []const u8) anyerror!void {
    return g_renderer.write(g_render_alloc, bytes, writeStdout);
}

const BASE_SYSTEM_PROMPT =
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
const AGENT_FILE = "AGENT.md";
/// When usage.prompt_tokens exceeds this between turns, trigger compaction.
const COMPACT_TOKEN_THRESHOLD: u32 = 25_000;
/// How many of the most recent turns to keep verbatim during compaction.
const COMPACT_KEEP_TAIL: usize = 4;

const CliOptions = struct {
    provider_kind: provider.Kind = .deepseek,
    model_override: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    show_help: bool = false,
    auto_approve: bool = false,
    no_stream: bool = false,
    no_color: bool = false,
    no_md: bool = false,
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
    \\  --no-md             disable markdown-lite rendering of streamed text
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

    var client = chat.Client.fromSelection(allocator, sel);

    var mcp_mgr = mcp.Manager.init(allocator);
    defer mcp_mgr.deinit();
    if (try resolveConfigDir(allocator)) |cd| {
        defer allocator.free(cd);
        mcp_mgr.loadConfig(cd) catch |err| {
            std.debug.print("warning: mcp.json load failed: {s}\n", .{@errorName(err)});
        };
    }

    const tools_json = try renderAllToolsJson(allocator, &mcp_mgr);
    defer allocator.free(tools_json);

    var stdin_buf: [16 * 1024]u8 = undefined;
    var stdin_file = std.fs.File.stdin();
    var stdin_reader = stdin_file.reader(&stdin_buf);
    const sr = &stdin_reader.interface;

    const interactive = stdin_file.isTty();
    style.detect(std.fs.File.stdout().isTty());
    if (opts.no_color) style.force(false);

    g_render_alloc = allocator;
    g_renderer.enabled = !opts.no_md;
    defer g_renderer.deinit(allocator);

    var policy = perm.Policy.init(allocator, opts.auto_approve, interactive);
    defer policy.deinit();

    const stream_enabled = !opts.no_stream;

    var history = message.History.init(allocator);
    defer history.deinit();

    const system_prompt = try buildSystemPrompt(allocator);
    defer allocator.free(system_prompt);

    if (opts.resume_session) |name| {
        loadSession(allocator, &history, name, system_prompt) catch |err| {
            std.debug.print("error: cannot resume session '{s}': {s}\n", .{ name, @errorName(err) });
            return err;
        };
    } else {
        try history.appendSystem(system_prompt);
    }

    installSigintHandler();

    if (opts.prompt) |p| {
        try runOneShot(allocator, client, tools_json, &policy, sr, stream_enabled, &history, p, &mcp_mgr);
    } else {
        try runRepl(allocator, &client, tools_json, &policy, sr, stream_enabled, &history, system_prompt, &cfg, &mcp_mgr);
    }
}

fn resolveConfigDir(allocator: std.mem.Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null) |xdg| {
        return try std.fs.path.join(allocator, &.{ xdg, "agent-naokiman" });
    }
    if (std.process.getEnvVarOwned(allocator, "HOME") catch null) |home| {
        defer allocator.free(home);
        return try std.fs.path.join(allocator, &.{ home, ".config", "agent-naokiman" });
    }
    return null;
}

fn renderAllToolsJson(allocator: std.mem.Allocator, mcp_mgr: *const mcp.Manager) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try s.beginArray();
    try tools.appendBuiltinsToArray(&s, &out.writer);
    try mcp_mgr.appendToolsToArray(&s, &out.writer);
    try s.endArray();
    return out.toOwnedSlice();
}

/// Build the effective system prompt: BASE_SYSTEM_PROMPT plus optional content
/// from `~/.config/agent-naokiman/AGENT.md` (global) and `./AGENT.md` (project).
/// Returns owned memory.
fn buildSystemPrompt(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, BASE_SYSTEM_PROMPT);

    // Global AGENT.md
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    if (home) |h| {
        defer allocator.free(h);
        const p = try std.fs.path.join(allocator, &.{ h, ".config", "agent-naokiman", AGENT_FILE });
        defer allocator.free(p);
        if (try readSmallFile(allocator, p, 256 * 1024)) |body| {
            defer allocator.free(body);
            try out.appendSlice(allocator, "\n\n# Global instructions (~/.config/agent-naokiman/AGENT.md)\n\n");
            try out.appendSlice(allocator, body);
        }
    }

    // Project-local AGENT.md
    if (try readSmallFile(allocator, AGENT_FILE, 256 * 1024)) |body| {
        defer allocator.free(body);
        try out.appendSlice(allocator, "\n\n# Project instructions (./AGENT.md)\n\n");
        try out.appendSlice(allocator, body);
    }

    return out.toOwnedSlice(allocator);
}

fn readSmallFile(allocator: std.mem.Allocator, path: []const u8, cap: usize) !?[]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    if (stat.size == 0 or stat.size > cap) return null;
    const body = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(body);
    _ = try file.readAll(body);
    return body;
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
        } else if (std.mem.eql(u8, a, "--no-md")) {
            opts.no_md = true;
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
    mcp_mgr: *mcp.Manager,
) !void {
    try history.appendUser(prompt);

    const reply = try driveAgent(allocator, client, tools_json, policy, stdin_reader, stream_enabled, history, mcp_mgr);
    if (!stream_enabled) try writeStdout(reply);
    try writeStdout("\n");
}

fn runRepl(
    allocator: std.mem.Allocator,
    client: *chat.Client,
    tools_json: []const u8,
    policy: *perm.Policy,
    stdin_reader: *std.Io.Reader,
    stream_enabled: bool,
    history: *message.History,
    system_prompt: []const u8,
    cfg: *config.Config,
    mcp_mgr: *mcp.Manager,
) !void {
    try printBanner(client.*);

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
            try history.appendSystem(system_prompt);
            try writeStdout("(history cleared)\n");
            continue;
        }
        if (std.mem.eql(u8, submitted, "/help")) {
            try writeStdout("/exit             end the session\n");
            try writeStdout("/clear            reset history\n");
            try writeStdout("/help             this message\n");
            try writeStdout("/save <name>      save the current session\n");
            try writeStdout("/load <name>      replace history with a saved session\n");
            try writeStdout("/sessions         list saved sessions\n");
            try writeStdout("/model <id>       switch model for the current provider\n");
            try writeStdout("/provider <name>  switch provider (deepseek / kimi / qwen)\n");
            continue;
        }
        if (std.mem.startsWith(u8, submitted, "/model ")) {
            const new_model = std.mem.trim(u8, submitted["/model ".len..], " \t");
            if (new_model.len == 0) {
                try writeStdout("(usage: /model <id>)\n");
                continue;
            }
            const owned = cfg.arena.allocator().dupe(u8, new_model) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            client.model = owned;
            try writeStdout("(switched model to '");
            try writeStdout(owned);
            try writeStdout("')\n");
            continue;
        }
        if (std.mem.startsWith(u8, submitted, "/provider ")) {
            const name = std.mem.trim(u8, submitted["/provider ".len..], " \t");
            const new_kind = provider.Kind.fromString(name) orelse {
                try writeStdout("(unknown provider — try deepseek, kimi, or qwen)\n");
                continue;
            };
            const sel = provider.select(cfg, new_kind, null) catch |err| switch (err) {
                error.MissingApiKey => {
                    try writeStdout("(error: ");
                    try writeStdout(provider.missingKeyEnvName(new_kind));
                    try writeStdout(" not set)\n");
                    continue;
                },
            };
            client.* = chat.Client.fromSelection(allocator, sel);
            try writeStdout("(switched to ");
            try writeStdout(client.kind.label());
            try writeStdout(" · model ");
            try writeStdout(client.model);
            try writeStdout(")\n");
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
            loadSession(allocator, history, name, system_prompt) catch |err| {
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
        const reply = driveAgent(allocator, client.*, tools_json, policy, stdin_reader, stream_enabled, history, mcp_mgr) catch |err| {
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

/// How many consecutive identical tool calls are allowed before we abort
/// the agent loop and tell the model to stop.
const MAX_CONSECUTIVE_REPEATS: usize = 3;

fn driveAgent(
    allocator: std.mem.Allocator,
    client: chat.Client,
    tools_json: []const u8,
    policy: *perm.Policy,
    stdin_reader: *std.Io.Reader,
    stream_enabled: bool,
    history: *message.History,
    mcp_mgr: *mcp.Manager,
) ![]const u8 {
    interrupt.clear();
    var prev_sig: ?[]u8 = null;
    defer if (prev_sig) |s| allocator.free(s);
    var prev_count: usize = 0;
    var turn: usize = 0;
    while (turn < MAX_TURNS) : (turn += 1) {
        if (history.items.items.len > COMPACT_KEEP_TAIL + 2) {
            // Last reading of usage from prior turn governs compaction; but
            // before turn 1 we have no usage info. Compaction happens lazily
            // at the bottom of the loop instead.
        }

        g_renderer.reset(g_render_alloc);
        var resp = if (stream_enabled)
            try client.chatStreaming(history, tools_json, streamSink)
        else
            try client.chat(history, tools_json);
        try g_renderer.flushFinal(g_render_alloc, writeStdout);
        defer resp.deinit();

        if (resp.interrupted) {
            try writeStyledLine("[interrupted by Ctrl+C]", "", style.bold_yellow);
            interrupt.clear();
            try history.appendAssistantText(resp.text);
            const last = history.items.items[history.items.items.len - 1];
            return last.assistant.text;
        }

        if (resp.tool_calls.len == 0) {
            try history.appendAssistantText(resp.text);
            try printUsageLine(resp.usage);
            try maybeCompact(allocator, client, history, resp.usage);
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

            // Detect a stuck loop: if the same tool is called with the
            // same arguments many times in a row, refuse and force the
            // model to either change approach or give up.
            const sig = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ tc.name, tc.arguments_json });
            errdefer allocator.free(sig);
            if (prev_sig) |p| {
                if (std.mem.eql(u8, p, sig)) {
                    prev_count += 1;
                } else {
                    allocator.free(p);
                    prev_sig = sig;
                    prev_count = 1;
                }
            } else {
                prev_sig = sig;
                prev_count = 1;
            }
            if (prev_count > 1 and sig.ptr != prev_sig.?.ptr) allocator.free(sig);

            if (prev_count >= MAX_CONSECUTIVE_REPEATS) {
                const msg =
                    "loop detected: this exact tool call has now been issued " ++
                    "three times in a row. The agent host is refusing further " ++
                    "calls. Stop, summarize what you found, and ask the user " ++
                    "for guidance instead of retrying.";
                try history.appendToolResult(tc.id, msg);
                try writeStyledLine("[loop detected, aborting tool calls for this turn]", "", style.bold_yellow);
                continue;
            }

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
                if (mcp.isQualifiedName(tc.name)) {
                    const maybe = mcp_mgr.execute(allocator, tc.name, tc.arguments_json) catch |err| {
                        break :blk std.fmt.allocPrint(
                            allocator,
                            "error: MCP tool '{s}' failed: {s}",
                            .{ tc.name, @errorName(err) },
                        ) catch return error.OutOfMemory;
                    };
                    if (maybe) |r| break :blk r;
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

        try maybeCompact(allocator, client, history, resp.usage);
    }

    return error.MaxTurnsExceeded;
}

fn printUsageLine(u: chat.Usage) !void {
    if (u.total_tokens == 0) return;
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[ctx {d} · in {d} · out {d}]", .{
        u.total_tokens,
        u.prompt_tokens,
        u.completion_tokens,
    }) catch return;
    try writeStdout("\n");
    try writeStdout(style.open(style.fg_blue));
    try writeStdout(line);
    try writeStdout(style.close());
    try writeStdout("\n");
}

/// Compact the history when prompt_tokens is approaching the model's
/// context limit. Replaces messages between the system prompt and the last
/// COMPACT_KEEP_TAIL turns with a single summary message.
fn maybeCompact(
    allocator: std.mem.Allocator,
    client: chat.Client,
    history: *message.History,
    usage: chat.Usage,
) !void {
    if (usage.prompt_tokens <= COMPACT_TOKEN_THRESHOLD) return;
    const items = history.items.items;
    if (items.len <= COMPACT_KEEP_TAIL + 2) return;

    try writeStyledLine("[context: ", "compacting older turns…", style.fg_yellow);

    // Build a summarization request with everything except the system prompt
    // and the last COMPACT_KEEP_TAIL items, plus a final user instruction.
    var summary_history = message.History.init(allocator);
    defer summary_history.deinit();
    try summary_history.appendSystem(
        \\You are summarizing an in-progress coding agent conversation so the
        \\agent can continue in a smaller context. Produce a tight, factual
        \\summary covering: (1) the user's overall goal, (2) what has been
        \\tried/discovered so far, (3) decisions made, (4) any pending
        \\sub-tasks. Be concise. Max 12 short bullet points.
    );

    const tail_start = items.len - COMPACT_KEEP_TAIL;
    var transcript: std.ArrayListUnmanaged(u8) = .empty;
    defer transcript.deinit(allocator);
    var i: usize = 1; // skip system
    while (i < tail_start) : (i += 1) {
        switch (items[i]) {
            .system => {},
            .user => |t| try transcript.writer(allocator).print("USER: {s}\n", .{t}),
            .assistant => |a| {
                if (a.text.len > 0) try transcript.writer(allocator).print("ASSISTANT: {s}\n", .{a.text});
                for (a.tool_calls) |tc| {
                    try transcript.writer(allocator).print("ASSISTANT_CALLED: {s}({s})\n", .{ tc.name, tc.arguments_json });
                }
            },
            .tool => |t| try transcript.writer(allocator).print("TOOL_RESULT: {s}\n", .{t.content}),
        }
    }
    try summary_history.appendUser(transcript.items);

    var summary_resp = client.chat(&summary_history, null) catch |err| {
        std.debug.print("warning: compaction failed: {s} (skipped)\n", .{@errorName(err)});
        return;
    };
    defer summary_resp.deinit();

    // Save the system prompt and the tail, replace the middle.
    const sys_msg = items[0];
    const sys_text = if (sys_msg == .system) sys_msg.system else "";

    // Snapshot tail items to dupes (they live in the arena, will be freed by clear()).
    var tail_dupes: std.ArrayListUnmanaged(message.Message) = .empty;
    defer tail_dupes.deinit(allocator);
    var j: usize = tail_start;
    while (j < items.len) : (j += 1) {
        try tail_dupes.append(allocator, items[j]);
    }

    // Stash the tail's text content via a temp arena allocator we'll free later.
    var tmp = std.heap.ArenaAllocator.init(allocator);
    defer tmp.deinit();
    const ta = tmp.allocator();

    const ToolCallSnap = struct { id: []const u8, name: []const u8, args: []const u8 };
    const Snap = union(enum) {
        sys: []const u8,
        usr: []const u8,
        ass_text: []const u8,
        ass_tools: struct { text: []const u8, calls: []ToolCallSnap },
        tool_res: struct { id: []const u8, content: []const u8 },
    };
    var snaps: std.ArrayListUnmanaged(Snap) = .empty;
    defer snaps.deinit(allocator);

    const sys_dup = try ta.dupe(u8, sys_text);
    try snaps.append(allocator, .{ .sys = sys_dup });

    const summary_dup = try ta.dupe(u8, summary_resp.text);
    const wrapped = try std.fmt.allocPrint(ta, "[Summary of earlier conversation]\n{s}", .{summary_dup});
    try snaps.append(allocator, .{ .usr = wrapped });

    for (tail_dupes.items) |m| {
        switch (m) {
            .system => |t| try snaps.append(allocator, .{ .sys = try ta.dupe(u8, t) }),
            .user => |t| try snaps.append(allocator, .{ .usr = try ta.dupe(u8, t) }),
            .assistant => |a| {
                if (a.tool_calls.len == 0) {
                    try snaps.append(allocator, .{ .ass_text = try ta.dupe(u8, a.text) });
                } else {
                    const calls = try ta.alloc(ToolCallSnap, a.tool_calls.len);
                    for (a.tool_calls, 0..) |tc, k| {
                        calls[k] = .{
                            .id = try ta.dupe(u8, tc.id),
                            .name = try ta.dupe(u8, tc.name),
                            .args = try ta.dupe(u8, tc.arguments_json),
                        };
                    }
                    try snaps.append(allocator, .{ .ass_tools = .{ .text = try ta.dupe(u8, a.text), .calls = calls } });
                }
            },
            .tool => |t| try snaps.append(allocator, .{ .tool_res = .{
                .id = try ta.dupe(u8, t.tool_call_id),
                .content = try ta.dupe(u8, t.content),
            } }),
        }
    }

    history.clear();
    for (snaps.items) |s| {
        switch (s) {
            .sys => |t| try history.appendSystem(t),
            .usr => |t| try history.appendUser(t),
            .ass_text => |t| try history.appendAssistantText(t),
            .ass_tools => |x| {
                const calls = try allocator.alloc(message.ToolCall, x.calls.len);
                defer allocator.free(calls);
                for (x.calls, 0..) |c, k| calls[k] = .{ .id = c.id, .name = c.name, .arguments_json = c.args };
                try history.appendAssistantToolCalls(x.text, calls);
            },
            .tool_res => |t| try history.appendToolResult(t.id, t.content),
        }
    }
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

/// Big ANSI Shadow lettering for "naokiman". Six rows tall, ~67 columns wide.
const BANNER_ROWS = [_][]const u8{
    "███╗   ██╗ █████╗  ██████╗ ██╗  ██╗██╗███╗   ███╗ █████╗ ███╗   ██╗",
    "████╗  ██║██╔══██╗██╔═══██╗██║ ██╔╝██║████╗ ████║██╔══██╗████╗  ██║",
    "██╔██╗ ██║███████║██║   ██║█████╔╝ ██║██╔████╔██║███████║██╔██╗ ██║",
    "██║╚██╗██║██╔══██║██║   ██║██╔═██╗ ██║██║╚██╔╝██║██╔══██║██║╚██╗██║",
    "██║ ╚████║██║  ██║╚██████╔╝██║  ██╗██║██║ ╚═╝ ██║██║  ██║██║ ╚████║",
    "╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝",
};

const BANNER_GRADIENT = [_][]const u8{
    style.bold_blue,
    style.bold_blue,
    style.bold_cyan,
    style.bold_cyan,
    style.fg_cyan,
    style.fg_cyan,
};

fn printBanner(client: chat.Client) !void {
    const bar = style.open(style.bold_blue);
    const accent = style.open(style.bold_cyan);
    const sub = style.open(style.fg_blue);
    const subtle = style.open(style.fg_cyan);
    const reset = style.close();

    try writeStdout("\n");
    for (BANNER_ROWS, BANNER_GRADIENT) |row, code| {
        try writeStdout("  ");
        try writeStdout(style.open(code));
        try writeStdout(row);
        try writeStdout(reset);
        try writeStdout("\n");
    }
    try writeStdout("\n");

    // Subtitle: provider · model
    try writeStdout("  ");
    try writeStdout(accent);
    try writeStdout("a coding agent");
    try writeStdout(reset);
    try writeStdout(sub);
    try writeStdout("  ·  ");
    try writeStdout(reset);
    try writeStdout(accent);
    try writeStdout(client.kind.label());
    try writeStdout(reset);
    try writeStdout(sub);
    try writeStdout("  ·  ");
    try writeStdout(reset);
    try writeStdout(accent);
    try writeStdout(client.model);
    try writeStdout(reset);
    try writeStdout("\n\n");

    // Slash commands and multiline hint, with the bar style we use elsewhere
    try writeStdout(bar);
    try writeStdout("  ▎ ");
    try writeStdout(reset);
    try writeStdout(subtle);
    try writeStdout("/exit  /clear  /help  /save <name>  /load <name>  /sessions");
    try writeStdout(reset);
    try writeStdout("\n");
    try writeStdout(bar);
    try writeStdout("  ▎ ");
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

fn loadSession(
    allocator: std.mem.Allocator,
    history: *message.History,
    name: []const u8,
    fallback_system: []const u8,
) !void {
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
        try history.appendSystem(fallback_system);
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
