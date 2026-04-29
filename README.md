# agent-naokiman

A multi-provider coding agent CLI written in [Zig](https://ziglang.org), inspired by [Claude Code](https://www.anthropic.com/claude-code) and similar tools.

> **Status**: Early prototype. Phases 0–2 are working — HTTP transport, multi-turn chat, an interactive REPL against DeepSeek, and a tool-use loop with `read_file` and `bash`. Multi-provider switching and TUI polish are not yet implemented.

## Goals

- A single CLI (`naokiman`) that can drive coding workflows against any of: DeepSeek, Moonshot Kimi, Alibaba Qwen
- Read files, run shell commands, edit code via LLM-driven tool calls (Claude Code style)
- Pure Zig, minimal dependencies, no runtime required

## Supported providers

| Provider | Models | Status |
|---|---|---|
| DeepSeek | `deepseek-chat`, `deepseek-v4-flash`, `deepseek-v4-pro` | chat + REPL + tool use |
| Moonshot Kimi | `kimi-k2`, `moonshot-v1-*` | planned |
| Alibaba Qwen | `qwen3-coder`, `qwen-max` | planned |

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

Tool use (Phase 2):

```sh
$ naokiman "Read README.md and tell me the language. One word."
[tool] read_file({"path": "README.md"})
Zig

$ naokiman "Run \`uname -s\` and tell me the OS name only."
[tool] bash({"command": "uname -s"})
Darwin
```

The model decides when to call tools. Each invocation is logged on stderr-style `[tool] ...` lines; the final natural-language answer is on stdout.

> **Warning**: the `bash` tool runs commands with no confirmation prompt. Don't aim it at production systems or destructive commands until permission prompts (Phase 6) are in place.

## Roadmap

- **Phase 0** — HTTP transport, env/`.env` loader, DeepSeek smoke test ✅
- **Phase 1** — Multi-turn chat history + interactive REPL ✅
- **Phase 2** — Tool-use loop with `read_file` and `bash` ✅
- **Phase 3** — Core tools: `write_file`, `edit_file`, `grep`, `glob`, `ls`
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
    │   └── bash.zig
    └── transport/
        └── http.zig        # std.http.Client wrapper, Bearer auth POST
```

## License

License has not been decided yet. Until a `LICENSE` file is added, the source is provided for reading and review only — no rights to use, modify, or redistribute are granted.
