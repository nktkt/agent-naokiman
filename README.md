# agent-naokiman

A multi-provider coding agent CLI written in [Zig](https://ziglang.org), inspired by [Claude Code](https://www.anthropic.com/claude-code) and similar tools.

> **Status**: Early prototype. Phase 0 complete — HTTP transport and a DeepSeek smoke test work end-to-end. The tool-use loop, multi-provider switching, REPL, and TUI are not yet implemented.

## Goals

- A single CLI (`naokiman`) that can drive coding workflows against any of: DeepSeek, Moonshot Kimi, Alibaba Qwen
- Read files, run shell commands, edit code via LLM-driven tool calls (Claude Code style)
- Pure Zig, minimal dependencies, no runtime required

## Supported providers

| Provider | Models | Status |
|---|---|---|
| DeepSeek | `deepseek-chat`, `deepseek-v4-flash`, `deepseek-v4-pro` | basic chat working |
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

Single-shot prompt (Phase 0):

```sh
$ naokiman "Reply with exactly: pong"
→ POST https://api.deepseek.com/chat/completions
→ model: deepseek-chat
→ user: Reply with exactly: pong
← status: 200
← assistant: pong
```

Interactive REPL and tool-use are coming in Phase 1+.

## Roadmap

- **Phase 0** — HTTP transport, env/`.env` loader, DeepSeek smoke test ✅
- **Phase 1** — Multi-turn chat history + interactive REPL
- **Phase 2** — Tool-use loop with `read_file` and `bash`
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
    ├── main.zig            # CLI entry, request assembly, response parsing
    ├── config.zig          # env + .env loader (global + project)
    └── transport/
        └── http.zig        # std.http.Client wrapper, Bearer auth POST
```

## License

License has not been decided yet. Until a `LICENSE` file is added, the source is provided for reading and review only — no rights to use, modify, or redistribute are granted.
