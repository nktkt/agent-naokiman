# agent-naokiman — Multi-Provider Coding Agent (Zig)

DeepSeek / Kimi / Qwen に対応した、Claude Code / OpenCode 相当の対話型コーディングエージェント CLI。

---

## 1. ゴール

- ターミナルで動く対話型エージェント
- ファイル読み書き・シェル実行・grep などのツールを LLM が呼び出して使う
- プロバイダ切替（DeepSeek / Kimi / Qwen）を CLI フラグまたは config で
- まずは MVP（チャット＋最小ツール）→ 段階的に Claude Code 級へ

## 2. 対応プロバイダ

| プロバイダ | 推奨モデル | OpenAI互換 | Anthropic互換 | 認証 env |
|---|---|---|---|---|
| DeepSeek | `deepseek-v4-flash` / `-pro` | ○ | ○（V4で対応） | `DEEPSEEK_API_KEY` |
| Kimi (Moonshot) | `kimi-k2` 系 | ○ | 要確認 | `MOONSHOT_API_KEY` |
| Qwen (Alibaba) | `qwen3-coder` / `qwen-max` | ○（DashScope） | 要確認 | `DASHSCOPE_API_KEY` |

**プロトコル統一の方針（要決定）**:
- 案A: **OpenAI互換に統一** — 3プロバイダ全部で確実に動く。実績多数。
- 案B: **Anthropic互換に統一** — Claude Code 系の設計を流用しやすい。ただし Kimi/Qwen 側の対応状況を要確認。
- 推奨: **案A から開始、後で案B レイヤを追加**できる構造にしておく。

## 3. アーキテクチャ

```
┌─────────────────────────────────────────┐
│ CLI (main.zig)                          │  サブコマンド: chat, run, config
├─────────────────────────────────────────┤
│ REPL / TUI (ui/)                        │  入力、ストリーム表示、Markdown
├─────────────────────────────────────────┤
│ Agent Core (agent.zig)                  │  ツールループ、履歴、コンテキスト
├──────────────┬─────────────┬────────────┤
│ Tools        │ Permission  │ Provider   │
│ (tools/)     │ (perm.zig)  │ (provider/)│
├──────────────┴─────────────┴────────────┤
│ Transport: HTTP / JSON / SSE            │
└─────────────────────────────────────────┘
```

## 4. ディレクトリ構成

```
agent-naokiman/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig              # エントリポイント、引数解析
│   ├── agent.zig             # Agent: run(), tool loop, history
│   ├── config.zig            # ~/.config/agent-naokiman/config.* 読込、env優先
│   ├── provider/
│   │   ├── mod.zig           # Provider interface (tagged union or vtable)
│   │   ├── openai_proto.zig  # 共通: messages/tool_calls 形式
│   │   ├── deepseek.zig
│   │   ├── kimi.zig
│   │   └── qwen.zig
│   ├── transport/
│   │   ├── http.zig          # std.http.Client ラッパー
│   │   ├── sse.zig           # Server-Sent Events
│   │   └── json_util.zig
│   ├── tools/
│   │   ├── mod.zig           # Tool interface、レジストリ、JSON Schema 生成
│   │   ├── read_file.zig
│   │   ├── write_file.zig
│   │   ├── edit_file.zig     # 検索/置換 or unified diff 適用
│   │   ├── bash.zig
│   │   ├── grep.zig
│   │   ├── glob.zig
│   │   └── ls.zig
│   ├── ui/
│   │   ├── repl.zig
│   │   ├── render.zig        # Markdown軽量レンダ
│   │   └── stream.zig
│   └── perm.zig              # 許可プロンプト、allowlist
└── PLAN.md
```

## 5. 開発フェーズ

### Phase 0 — 基盤（完了）
- [x] `build.zig` セットアップ（Zig 0.15.2）
- [x] `transport/http.zig`: HTTPS POST + JSON
- [x] `config.zig`: env 優先、`~/.config/agent-naokiman/.env` + `./.env` 対応
- [x] スモークテスト: DeepSeek に1リクエスト通す

### Phase 1 — 単一プロバイダ チャット（完了）
- [x] OpenAI互換メッセージ型（`role`, `content`）
- [x] DeepSeek プロバイダ実装
- [x] `History` 構造体: arena ベース履歴
- [x] CLI: `naokiman "質問文"` で one-shot、引数なしで REPL
- [x] REPL コマンド: `/exit`, `/clear`, `/help`

### Phase 2 — ツール実行ループ（完了）★ MVP の核
- [x] `Tool` インターフェース、JSON Schema 定義（`tools/mod.zig`）
- [x] `read_file`, `bash` の2ツールを実装
- [x] LLM の `tool_calls` を実行 → `tool` ロールで結果返却 → 終了条件まで反復
- [x] 停止: `finish_reason == "stop"`、最大ターン数 20

### Phase 3 — コアツール一式（完了）
- [x] `write_file`（新規/上書き、4 MiB 上限）
- [x] `edit_file`（厳密一致 search/replace、tmp → rename でアトミック）
- [x] `grep`（リテラル部分一致 + glob include）, `glob`（`*` `**` `?`）, `ls`
- [x] ツールエラーを LLM 可読な形で返す（in-band string）

### Phase 4 — マルチプロバイダ（次フェーズ）
- [ ] Provider 抽象化（tagged union）
- [ ] **Kimi (Moonshot)** 実装
  - 既定 base URL: `https://api.moonshot.ai/v1`（intl）/ `https://api.moonshot.cn/v1`（CN）
  - 既定モデル: `kimi-k2.6`（2026-04-20 リリース、256K context）
  - 注意: `tool_choice="required"` 不可、temperature ∈ [0, 1]、`max_completion_tokens` 推奨
- [ ] **Qwen (DashScope)** 実装
  - 既定 base URL: `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`
  - 既定モデル: `qwen3-coder-plus`（256K, YaRN で 1M）
  - 注意: `parallel_tool_calls: true` 必須、stream + tools 不可、tool 結果は string 必須
- [ ] CLI: `--provider {deepseek|kimi|qwen} --model <id>`
- [ ] config: 既定プロバイダ切替

### Phase 5 — ストリーミング（完了）
- [x] SSE パーサ（`data: {...}` / `[DONE]` / 空行）
- [x] テキスト delta は即時 stdout、`tool_calls` は index 単位で id/name/arguments 蓄積
- [x] `--no-stream` で従来のバッファ動作にフォールバック
- [ ] Ctrl+C で中断（後続）

### Phase 6 — 権限とサンドボックス（完了）
- [x] `bash` / `write_file` / `edit_file` 実行前の対話プロンプト
- [x] セッション内 allowlist（exact-match と tool 単位 blanket）
- [x] `--yes` で自動承認、非 TTY 時は自動 deny
- [x] 危険コマンド検出（`rm -rf /`, `curl\|sh`, `dd if=`, `mkfs`, `chmod -R 777`, fork bomb, sudo, force-push 等）→ プロンプトに `⚠ DANGER:` 付与
- [x] allowlist の永続化（`~/.config/agent-naokiman/allowed.json`、option 2 を選んだ exact pair が次回起動時に自動承認）

### Phase 7 — TUI/REPL 改善（任意、数日）
- [ ] マルチライン入力
- [ ] Markdown 軽量レンダ
- [ ] セッション保存/再開

## 6. 技術選定

- **Zig**: 0.15.2（インストール済み。`std.http.Client` の API は 0.14 と差分あり、実装時に注意）
- **依存**: 標準ライブラリ中心。外部依存は最小限
- **JSON**: `std.json`
- **TLS**: `std.crypto.tls`
- **TUI**: 最初は raw stdout。必要になったら検討
- **設定ファイル**: 簡易 KV か JSON。TOML パーサは入れない
- **設定ディレクトリ**: `~/.config/agent-naokiman/`

## 7. プロバイダ抽象化のスケッチ

```zig
pub const Provider = union(enum) {
    deepseek: DeepSeek,
    kimi: Kimi,
    qwen: Qwen,

    pub fn chat(self: *Provider, req: ChatRequest) !ChatResponse { ... }
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    tools: []const ToolDef,
    stream: bool = false,
};
```

OpenAI互換に揃えれば各プロバイダ実装は「ベースURL・モデル名・APIキー」を差し替えるだけで済む。

## 8. オープンな決定事項

1. **プロジェクト名** — `agent-naokiman`（確定）
2. **プロトコル統一** — OpenAI互換 / Anthropic互換 / 両対応のうちどれ
3. **MVP 範囲** — Phase 2 終了時点（read_file + bash で動く）でリリース判定するか
4. **ライセンス** — MIT / Apache-2.0 / 非公開
5. **Edit ツールの方式** — 厳密一致の search/replace（Claude Code 流）か unified diff か
6. **コンテキスト管理** — V4 の 1M を活かして圧縮なし、それとも先に圧縮実装

## 9. リスクと注意点

- **Zig 標準 HTTP の TLS 安定性**: 大容量レスポンスや SSE で挙動を要確認
- **JSON のメモリ管理**: arena allocator を1ターン単位で使う設計推奨
- **ツール選択の精度**: プロンプト設計の比重が大きい。最初から system prompt をしっかり書く
- **bash ツールの安全性**: シェル経由ではなく `argv` 配列で実行。`/bin/sh -c` は明示的フラグ時のみ
- **マルチプロバイダの差異**: stop_reason、tool_call の構造、エラー形式に微妙な差。プロバイダごとに正規化レイヤを置く

## 10. 直近のアクション

最初に決めるべき3点:

1. プロトコル統一の方針（推奨: OpenAI互換から）
2. Zig バージョン（確定: 0.15.2）
3. Phase 0 に着手して良いか（DeepSeek API キーが手元にあるか）
