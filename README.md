# agent-naokiman

A multi-provider coding agent CLI written in [Zig](https://ziglang.org), inspired by [Claude Code](https://www.anthropic.com/claude-code) and similar tools.

> **Status**: Early prototype with all core phases (0–7) plus the longevity essentials — HTTP transport, multi-turn chat, an interactive REPL with multi-line input and saveable sessions, a tool-use loop with seven core tools (`read_file` / `write_file` / `edit_file` / `bash` / `ls` / `glob` / `grep`), provider switching across DeepSeek / Moonshot Kimi / Alibaba Qwen, per-tool approval prompts with danger detection and a persistent allowlist, SSE streaming, **per-turn token usage display, automatic context compaction when usage approaches the limit, project-local `AGENT.md` ingestion, and Ctrl+C interrupt during streaming**.

## Goals

- A single CLI (`naokiman`) that can drive coding workflows against any of: DeepSeek, Moonshot Kimi, Alibaba Qwen
- Read files, run shell commands, edit code via LLM-driven tool calls (Claude Code style)
- Pure Zig, minimal dependencies, no runtime required

## Supported providers

| Provider | CLI flag | Default model | Default base URL |
|---|---|---|---|
| DeepSeek | `--provider deepseek` (default) | `deepseek-chat` | `https://api.deepseek.com/v1` |
| Moonshot Kimi | `--provider kimi` | `kimi-k2.6` | `https://api.moonshot.ai/v1` |
| Alibaba Qwen | `--provider qwen` | `qwen3-coder-plus` | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` |

All three speak an OpenAI-compatible `/chat/completions` API, so they share a single transport layer. Per-provider quirks (e.g. Qwen requiring `parallel_tool_calls: true`) are handled inside the client. Override the default model with `--model <id>` and the base URL via the matching environment variable (`DEEPSEEK_BASE_URL`, `MOONSHOT_BASE_URL`, `DASHSCOPE_BASE_URL`).

## Requirements

- Zig **0.15.2**
- A DeepSeek API key (other providers optional)

## Build

```sh
zig build
./zig-out/bin/naokiman "Hello"
```

Install into `~/.local/bin` (must be on `PATH`):

```sh
zig build --prefix ~/.local
naokiman "Hello"
```

## Project context (`AGENT.md`)

If a file named `AGENT.md` exists in the current working directory, its contents are appended to the system prompt at startup. Use it to capture project-specific conventions, build commands, or off-limits paths so you don't have to retype them every session. A second `AGENT.md` at `~/.config/agent-naokiman/AGENT.md` is also loaded as a global preface (project-local overrides win because it comes last).

```markdown
# Project rules
- Run `cargo check` before suggesting code changes.
- Never touch files under `vendored/`.
- Tests live in `tests/integration/*.rs`.
```

## Configuration

`naokiman` reads configuration from these sources, with later sources overriding earlier ones:

1. `~/.config/agent-naokiman/.env` — global defaults
2. `./.env` — project-local override
3. Environment variables — highest priority

Example `.env`:

```sh
DEEPSEEK_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
DEEPSEEK_BASE_URL=https://api.deepseek.com/v1

# Optional, for --provider kimi
# MOONSHOT_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# MOONSHOT_BASE_URL=https://api.moonshot.ai/v1

# Optional, for --provider qwen
# DASHSCOPE_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# DASHSCOPE_BASE_URL=https://dashscope-intl.aliyuncs.com/compatible-mode/v1
```

See [`.env.example`](./.env.example) for an annotated template.

Restrict permissions on the global config file:

```sh
chmod 600 ~/.config/agent-naokiman/.env
```

## Usage

One-shot prompt:

```sh
$ naokiman "Reply with exactly: pong"
pong
```

Pick a different provider or model:

```sh
$ naokiman --provider kimi "What model are you?"
$ naokiman --provider qwen --model qwen3-coder-flash "Write fizzbuzz in Python."
$ naokiman --help
```

Interactive REPL (multi-turn, history retained, blue-based ANSI styling):

```text
$ naokiman

  ███╗   ██╗ █████╗  ██████╗ ██╗  ██╗██╗███╗   ███╗ █████╗ ███╗   ██╗
  ████╗  ██║██╔══██╗██╔═══██╗██║ ██╔╝██║████╗ ████║██╔══██╗████╗  ██║
  ██╔██╗ ██║███████║██║   ██║█████╔╝ ██║██╔████╔██║███████║██╔██╗ ██║
  ██║╚██╗██║██╔══██║██║   ██║██╔═██╗ ██║██║╚██╔╝██║██╔══██║██║╚██╗██║
  ██║ ╚████║██║  ██║╚██████╔╝██║  ██╗██║██║ ╚═╝ ██║██║  ██║██║ ╚████║
  ╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝

  a coding agent  ·  deepseek  ·  deepseek-chat

  ▎ /exit  /clear  /help  /save <name>  /load <name>  /sessions
  ▎ multiline: <<< … <<<

you> My favorite number is 42.
naokiman> Nice. 42 is a classic.

you> /save chat1
(saved as 'chat1')

you> /exit

$ naokiman --resume chat1
you> What is my favorite number?
naokiman> Your favorite number is 42.
```

Multi-line input (paste a stack trace, snippet, etc.):

```
you> <<<
... fn main() {
...     // ...
... }
... <<<
naokiman> ...
```

Tool use:

```sh
$ naokiman "Read README.md and tell me the language. One word."
[tool] read_file({"path": "README.md"})
Zig

$ naokiman "Run \`uname -s\` and tell me the OS name only."
[tool] bash({"command": "uname -s"})
Darwin

$ naokiman "List files under src/tools/. Just the count."
[tool] glob({"pattern": "src/tools/**/*.zig"})
8
```

Available tools (the LLM picks them automatically):

| Tool | Purpose |
|---|---|
| `read_file(path)` | Read a UTF-8 text file (1 MiB cap) |
| `write_file(path, content)` | Create or overwrite a file (4 MiB cap, parents auto-created) |
| `edit_file(path, old_string, new_string)` | Atomic exact-match search/replace (must be unique) |
| `multi_edit(path, edits[])` | Apply several `{old_string, new_string}` edits atomically (each match must be unique at its turn) |
| `bash(command)` | Run via `/bin/sh -c` (64 KiB output cap) |
| `ls(path)` | List immediate directory entries |
| `glob(pattern, root)` | Walk tree and match `*` / `**` / `?` |
| `grep(pattern, root, include)` | Recursive substring search with optional file glob filter |

The model decides when to call tools. Each invocation is logged as `[tool] name(args)` lines; the final natural-language answer is on stdout.

### Token usage and context compaction

After every turn the agent prints a one-line usage summary in dim blue:

```
[ctx 12453 · in 11890 · out 563]
```

When `prompt_tokens` exceeds 25 k, the agent automatically summarizes the older turns (everything between the system prompt and the last 4 messages) using a side `chat()` call, then replaces them with a single bullet-list summary. You'll see `[context: compacting older turns…]` once the threshold is crossed; the conversation continues in the now-reclaimed budget.

### Interrupt

Press `Ctrl+C` during a streaming response and the SSE loop unwinds at the next chunk; whatever has streamed so far is kept in history. The flag clears between turns so the next prompt works normally.

### File attachments

Attach one or more files to the initial prompt with `-f` / `--file` (repeatable):

```sh
$ naokiman -f bug-report.md -f stacktrace.txt "What's likely going wrong?"
```

Each file is read (up to 256 KiB per file) and embedded in the user message inside `<file path="...">…</file>` tags. The model sees the path and contents alongside your prompt — handy for "explain this stack trace" style questions where you'd otherwise need an extra `read_file` round-trip. Image attachments via the multimodal API are not yet implemented; for now `-f` is text-only.

### Edit diffs

Whenever `edit_file`, `multi_edit`, or `write_file` runs successfully, the agent prints a summary line in dim gray followed by a colored block diff (red `-` for removed lines, green `+` for added lines). The same diff is fed back to the model in the tool result so it can verify the change without re-reading the file.

### Progress indicator

Between sending a request and the first streamed token, naokiman prints a dim `[thinking…]` line. As soon as the first byte arrives (or the request completes for non-streaming mode), the line is cleared and the actual output begins. Suppressed when stdout isn't a TTY.

### MCP servers

`agent-naokiman` is also an [MCP](https://modelcontextprotocol.io) host: it can spawn external tool servers and expose their tools to the LLM alongside the built-in seven.

Define servers in `~/.config/agent-naokiman/mcp.json`:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    },
    "fetch": {
      "command": "uvx",
      "args": ["mcp-server-fetch"]
    }
  }
}
```

On startup, every server is spawned, an `initialize` handshake runs, and `tools/list` populates the catalogue. Tools are exposed to the LLM under the qualified name `mcp__<server>__<tool>`. When the LLM calls one, the request is routed back to the matching server over JSON-RPC stdio. Approval prompts apply only to the built-in destructive tools — MCP tools are passed through (you trust the servers you configured). If a server's child process dies between calls, the agent automatically respawns it once and retries the call before bubbling the failure.

Only the `tools` capability is supported in this build; `resources`, `prompts`, and `sampling` are not yet implemented.

### Markdown rendering

Streamed assistant output is passed through a small line-buffered renderer that highlights:

- inline `` `code` `` spans → cyan
- `**bold**` → bold
- `# headers`, `## subheaders` → bold (cyan for top level)
- ``` ```code fences``` ``` → fence delimiters dim, contents in cyan

The renderer activates only when ANSI styling is on (TTY + no `NO_COLOR`). Pass `--no-md` to disable it explicitly while keeping color elsewhere.

### Loop detection

If the model calls the same tool with the same arguments three turns in a row, the agent host appends a "loop detected" message to the conversation and skips the third execution. This breaks pathological retry loops where a model gets fixated on a failing call.

### Permissions

`bash`, `write_file`, and `edit_file` require interactive approval before each call. When you run `naokiman` in a terminal you'll see:

```
[approval needed] tool: bash
  args: {"command": "rm -rf /tmp/foo"}
  1) yes, just this once
  2) yes, remember this exact command for the session
  3) yes, allow ALL bash calls for the session
  4) no, deny
choice [1-4, default 4]:
```

Press `1` / `y` to allow this single call, `2` / `e` to remember the exact `(tool, args)` pair, `3` / `a` to blanket-allow the tool, anything else (or just Enter) to deny.

When stdin is not a TTY (piped input, CI), all destructive calls are denied automatically. Pass `--yes` / `-y` to auto-approve in trusted automated contexts.

Read-only tools (`read_file`, `ls`, `glob`, `grep`) never require approval.

**Danger detection.** `bash` commands matching well-known destructive patterns get a `⚠ DANGER:` line in the prompt — `rm -rf /`, `rm -rf ~`, `curl … | sh`, `wget … | bash`, `dd if=`, `mkfs`, `chmod -R 777`, sudo, fork bombs, force-push, and `git reset --hard` are flagged. The detection is informational; the user still chooses to allow or deny.

**Persistent allowlist.** Option `2` in the prompt (yes, remember this exact command) writes the `(tool, args)` pair to `~/.config/agent-naokiman/allowed.json` (mode 0600). On the next run, that exact call is auto-approved without a prompt. Blanket per-tool grants (option `3`) are session-only and never persisted. Delete the file to forget all approvals.

## Roadmap

- **Phase 0** — HTTP transport, env/`.env` loader, DeepSeek smoke test ✅
- **Phase 1** — Multi-turn chat history + interactive REPL ✅
- **Phase 2** — Tool-use loop with `read_file` and `bash` ✅
- **Phase 3** — Core tools: `write_file`, `edit_file`, `ls`, `glob`, `grep` ✅
- **Phase 4** — Multi-provider switching (DeepSeek, Kimi, Qwen) ✅
- **Phase 5** — SSE streaming (token-by-token output) ✅
- **Phase 6** — Approval prompts + danger detection (`rm -rf /`, `curl|sh`, etc.) + persistent allowlist ✅
- **Phase 7** — REPL polish: multiline heredoc input, `/save`/`/load`/`/sessions`, `--resume <name>`, ANSI-styled banner & prompts ✅ (Markdown rendering still TODO)
- **Phase 4** — Multi-provider abstraction (Kimi, Qwen)
- **Phase 5** — Streaming responses (SSE)
- **Phase 6** — Permission prompts, sandbox-style guardrails
- **Phase 7** — TUI polish, Markdown rendering

The full design document (in Japanese) lives in [`PLAN.md`](./PLAN.md).

## Project layout

```
agent-naokiman/
├── build.zig
├── build.zig.zon
├── PLAN.md
├── README.md
└── src/
    ├── main.zig            # CLI entry, one-shot/REPL dispatch, tool-use loop
    ├── config.zig          # env + .env loader (global + project)
    ├── message.zig         # Message tagged union + tool_calls serialization
    ├── chat.zig            # OpenAI-compatible chat client (DeepSeek/Kimi/Qwen)
    ├── provider.zig        # Provider kind enum + per-provider config selection
    ├── perm.zig            # Approval policy + interactive prompt
    ├── style.zig           # ANSI helpers, NO_COLOR / --no-color aware
    ├── render.zig          # markdown-lite stream renderer (`code`, **bold**, fences, headers)
    ├── interrupt.zig       # SIGINT handler for Ctrl+C abort
    ├── mcp.zig             # MCP client: spawn servers, initialize, tools/list, tools/call
    ├── tools/
    │   ├── mod.zig         # Tool interface, registry, JSON-schema rendering
    │   ├── read_file.zig
    │   ├── write_file.zig  # 4 MiB cap, parents auto-created
    │   ├── edit_file.zig   # atomic via .tmp + rename, unique-match required
    │   ├── multi_edit.zig  # batch atomic edits, each match must be unique
    │   ├── bash.zig        # /bin/sh -c, 64 KiB output cap
    │   ├── ls.zig
    │   ├── glob.zig        # *, **, ? matcher (anchored full-path match)
    │   └── grep.zig        # recursive substring search with glob include
    └── transport/
        └── http.zig        # std.http.Client wrapper, Bearer auth POST
```

## License

MIT — see [`LICENSE`](./LICENSE).
