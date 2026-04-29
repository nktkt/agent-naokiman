# agent-naokiman

A multi-provider coding agent CLI written in [Zig](https://ziglang.org), inspired by [Claude Code](https://www.anthropic.com/claude-code) and similar tools.

> **Status**: Early prototype. Phases 0–3 are working — HTTP transport, multi-turn chat, an interactive REPL against DeepSeek, and a tool-use loop with seven core tools (`read_file`, `write_file`, `edit_file`, `bash`, `ls`, `glob`, `grep`). Multi-provider switching and TUI polish are not yet implemented.

## Goals

- A single CLI (`naokiman`) that can drive coding workflows against any of: DeepSeek, Moonshot Kimi, Alibaba Qwen
- Read files, run shell commands, edit code via LLM-driven tool calls (Claude Code style)
- Pure Zig, minimal dependencies, no runtime required

## Supported providers

| Provider | Models | Status |
|---|---|---|
| DeepSeek | `deepseek-chat`, `deepseek-v4-flash`, `deepseek-v4-pro` | chat + REPL + tool use |
| Moonshot Kimi | `kimi-k2.6`, `moonshot-v1-*` | planned (Phase 4) |
| Alibaba Qwen | `qwen3-coder-plus`, `qwen3-max` | planned (Phase 4) |

All three speak an OpenAI-compatible API, so they share a single transport layer behind the abstraction.

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

## Configuration

`naokiman` reads configuration from these sources, with later sources overriding earlier ones:

1. `~/.config/agent-naokiman/.env` — global defaults
2. `./.env` — project-local override
3. Environment variables — highest priority

Example `.env`:

```sh
DEEPSEEK_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
DEEPSEEK_BASE_URL=https://api.deepseek.com

# MOONSHOT_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# DASHSCOPE_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

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

Interactive REPL (multi-turn, history retained):

```sh
$ naokiman
naokiman REPL — model: deepseek-chat
commands: /exit  /clear  /help

you> My favorite number is 42.
naokiman> Nice. 42 is a classic.

you> What is my favorite number?
naokiman> Your favorite number is 42.

you> /exit
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
| `bash(command)` | Run via `/bin/sh -c` (64 KiB output cap) |
| `ls(path)` | List immediate directory entries |
| `glob(pattern, root)` | Walk tree and match `*` / `**` / `?` |
| `grep(pattern, root, include)` | Recursive substring search with optional file glob filter |

The model decides when to call tools. Each invocation is logged as `[tool] name(args)` lines; the final natural-language answer is on stdout.

> **Warning**: the `bash` and `write_file` tools run with no confirmation prompt. Don't aim them at production systems until permission prompts (Phase 6) are in place.

## Roadmap

- **Phase 0** — HTTP transport, env/`.env` loader, DeepSeek smoke test ✅
- **Phase 1** — Multi-turn chat history + interactive REPL ✅
- **Phase 2** — Tool-use loop with `read_file` and `bash` ✅
- **Phase 3** — Core tools: `write_file`, `edit_file`, `ls`, `glob`, `grep` ✅
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
    ├── deepseek.zig        # DeepSeek chat client (text + tool_calls)
    ├── tools/
    │   ├── mod.zig         # Tool interface, registry, JSON-schema rendering
    │   ├── read_file.zig
    │   ├── write_file.zig  # 4 MiB cap, parents auto-created
    │   ├── edit_file.zig   # atomic via .tmp + rename, unique-match required
    │   ├── bash.zig        # /bin/sh -c, 64 KiB output cap
    │   ├── ls.zig
    │   ├── glob.zig        # *, **, ? matcher (anchored full-path match)
    │   └── grep.zig        # recursive substring search with glob include
    └── transport/
        └── http.zig        # std.http.Client wrapper, Bearer auth POST
```

## License

License has not been decided yet. Until a `LICENSE` file is added, the source is provided for reading and review only — no rights to use, modify, or redistribute are granted.
