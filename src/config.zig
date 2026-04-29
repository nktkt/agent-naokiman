const std = @import("std");

pub const APP_NAME = "agent-naokiman";

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    deepseek_api_key: ?[]const u8 = null,
    deepseek_base_url: []const u8 = "https://api.deepseek.com",
    moonshot_api_key: ?[]const u8 = null,
    moonshot_base_url: []const u8 = "https://api.moonshot.cn",
    dashscope_api_key: ?[]const u8 = null,
    dashscope_base_url: []const u8 = "https://dashscope.aliyuncs.com/compatible-mode/v1",

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

/// Precedence (lowest → highest, last write wins):
///   1. ~/.config/agent-naokiman/.env
///   2. ./.env  (project-local override)
///   3. environment variables
pub fn load(out: *Config, parent_allocator: std.mem.Allocator) !void {
    out.* = .{ .arena = std.heap.ArenaAllocator.init(parent_allocator) };
    errdefer out.arena.deinit();
    const a = out.arena.allocator();

    if (try globalEnvPath(a)) |p| try loadDotEnv(a, out, p);
    try loadDotEnv(a, out, ".env");

    out.deepseek_api_key = try envOpt(a, "DEEPSEEK_API_KEY") orelse out.deepseek_api_key;
    out.deepseek_base_url = try envOpt(a, "DEEPSEEK_BASE_URL") orelse out.deepseek_base_url;
    out.moonshot_api_key = try envOpt(a, "MOONSHOT_API_KEY") orelse out.moonshot_api_key;
    out.moonshot_base_url = try envOpt(a, "MOONSHOT_BASE_URL") orelse out.moonshot_base_url;
    out.dashscope_api_key = try envOpt(a, "DASHSCOPE_API_KEY") orelse out.dashscope_api_key;
    out.dashscope_base_url = try envOpt(a, "DASHSCOPE_BASE_URL") orelse out.dashscope_base_url;
}

/// Returns the absolute path to the global config .env, or null if HOME / XDG_CONFIG_HOME
/// cannot be resolved.
pub fn globalEnvPath(a: std.mem.Allocator) !?[]const u8 {
    if (try envOpt(a, "XDG_CONFIG_HOME")) |xdg| {
        return try std.fs.path.join(a, &.{ xdg, APP_NAME, ".env" });
    }
    if (try envOpt(a, "HOME")) |home| {
        return try std.fs.path.join(a, &.{ home, ".config", APP_NAME, ".env" });
    }
    return null;
}

fn envOpt(a: std.mem.Allocator, name: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(a, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => err,
    };
}

fn loadDotEnv(a: std.mem.Allocator, cfg: *Config, path: []const u8) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const max_size: usize = 64 * 1024;
    const stat = try file.stat();
    if (stat.size > max_size) return error.DotEnvTooLarge;
    const body = try a.alloc(u8, @intCast(stat.size));
    _ = try file.readAll(body);

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or
            (val[0] == '\'' and val[val.len - 1] == '\''))) {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "DEEPSEEK_API_KEY")) cfg.deepseek_api_key = try a.dupe(u8, val);
        if (std.mem.eql(u8, key, "DEEPSEEK_BASE_URL")) cfg.deepseek_base_url = try a.dupe(u8, val);
        if (std.mem.eql(u8, key, "MOONSHOT_API_KEY")) cfg.moonshot_api_key = try a.dupe(u8, val);
        if (std.mem.eql(u8, key, "MOONSHOT_BASE_URL")) cfg.moonshot_base_url = try a.dupe(u8, val);
        if (std.mem.eql(u8, key, "DASHSCOPE_API_KEY")) cfg.dashscope_api_key = try a.dupe(u8, val);
        if (std.mem.eql(u8, key, "DASHSCOPE_BASE_URL")) cfg.dashscope_base_url = try a.dupe(u8, val);
    }
}
