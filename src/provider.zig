const std = @import("std");
const config = @import("config.zig");

pub const Kind = enum {
    deepseek,
    kimi,
    qwen,

    pub fn fromString(s: []const u8) ?Kind {
        if (std.mem.eql(u8, s, "deepseek")) return .deepseek;
        if (std.mem.eql(u8, s, "kimi")) return .kimi;
        if (std.mem.eql(u8, s, "moonshot")) return .kimi;
        if (std.mem.eql(u8, s, "qwen")) return .qwen;
        if (std.mem.eql(u8, s, "dashscope")) return .qwen;
        return null;
    }

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .deepseek => "deepseek",
            .kimi => "kimi",
            .qwen => "qwen",
        };
    }

    pub fn defaultModel(self: Kind) []const u8 {
        return switch (self) {
            .deepseek => "deepseek-chat",
            .kimi => "kimi-k2.6",
            .qwen => "qwen3-coder-plus",
        };
    }
};

pub const Selection = struct {
    kind: Kind,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
};

pub const SelectError = error{
    MissingApiKey,
};

/// Resolve a provider selection from config, falling back to per-kind defaults
/// when explicit overrides are not given. Returns owned slices borrowed from
/// `cfg`'s arena — they live as long as the Config does.
pub fn select(cfg: *const config.Config, kind: Kind, model_override: ?[]const u8) SelectError!Selection {
    const model: []const u8 = model_override orelse kind.defaultModel();

    return switch (kind) {
        .deepseek => .{
            .kind = .deepseek,
            .api_key = cfg.deepseek_api_key orelse return error.MissingApiKey,
            .base_url = cfg.deepseek_base_url,
            .model = model,
        },
        .kimi => .{
            .kind = .kimi,
            .api_key = cfg.moonshot_api_key orelse return error.MissingApiKey,
            .base_url = cfg.moonshot_base_url,
            .model = model,
        },
        .qwen => .{
            .kind = .qwen,
            .api_key = cfg.dashscope_api_key orelse return error.MissingApiKey,
            .base_url = cfg.dashscope_base_url,
            .model = model,
        },
    };
}

pub fn missingKeyEnvName(kind: Kind) []const u8 {
    return switch (kind) {
        .deepseek => "DEEPSEEK_API_KEY",
        .kimi => "MOONSHOT_API_KEY",
        .qwen => "DASHSCOPE_API_KEY",
    };
}
