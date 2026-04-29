const std = @import("std");

/// Tools whose execution must be confirmed by the user (or auto-approved
/// via flag). Read-only tools (read_file, ls, glob, grep) are never gated.
pub fn isDestructive(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "bash") or
        std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit_file");
}

pub const Policy = struct {
    allocator: std.mem.Allocator,
    auto_approve_all: bool,
    interactive: bool,
    /// Tool names that have been blanket-approved for the rest of this session.
    allow_all_for_tool: std.StringHashMapUnmanaged(void) = .empty,
    /// Exact `tool_name + "\x00" + args_json` keys approved for the session.
    allow_exact: std.StringHashMapUnmanaged(void) = .empty,
    /// Backing arena for keys we own (tool names and exact-keys).
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, auto_approve_all: bool, interactive: bool) Policy {
        return .{
            .allocator = allocator,
            .auto_approve_all = auto_approve_all,
            .interactive = interactive,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Policy) void {
        self.allow_all_for_tool.deinit(self.allocator);
        self.allow_exact.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Returns true if the tool is allowed to run.
    /// Writes the prompt (when interactive) to `writer`; reads the user's
    /// reply from `reader`. Both must be non-null when `self.interactive`
    /// is true and approval is needed.
    pub fn approve(
        self: *Policy,
        tool_name: []const u8,
        args_json: []const u8,
        reader: *std.Io.Reader,
        writer: *const fn ([]const u8) anyerror!void,
    ) !bool {
        if (self.auto_approve_all) return true;
        if (!isDestructive(tool_name)) return true;
        if (self.allow_all_for_tool.contains(tool_name)) return true;

        const exact_key = try makeExactKey(self.arena.allocator(), tool_name, args_json);
        if (self.allow_exact.contains(exact_key)) return true;

        if (!self.interactive) {
            try writer("[permission] auto-deny (no TTY) for ");
            try writer(tool_name);
            try writer("\n");
            return false;
        }

        const decision = try self.promptUser(tool_name, args_json, reader, writer);
        switch (decision) {
            .allow_once => return true,
            .allow_session_exact => {
                try self.allow_exact.put(self.allocator, exact_key, {});
                return true;
            },
            .allow_session_all => {
                const owned_name = try self.arena.allocator().dupe(u8, tool_name);
                try self.allow_all_for_tool.put(self.allocator, owned_name, {});
                return true;
            },
            .deny => return false,
        }
    }

    const Decision = enum { allow_once, allow_session_exact, allow_session_all, deny };

    fn promptUser(
        self: *Policy,
        tool_name: []const u8,
        args_json: []const u8,
        reader: *std.Io.Reader,
        writer: *const fn ([]const u8) anyerror!void,
    ) !Decision {
        _ = self;
        try writer("\n[approval needed] tool: ");
        try writer(tool_name);
        try writer("\n  args: ");
        try writer(args_json);
        try writer("\n  1) yes, just this once\n");
        try writer("  2) yes, remember this exact command for the session\n");
        try writer("  3) yes, allow ALL ");
        try writer(tool_name);
        try writer(" calls for the session\n");
        try writer("  4) no, deny\n");
        try writer("choice [1-4, default 4]: ");

        const maybe = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return .deny,
            else => return err,
        };
        const raw = maybe orelse return .deny;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return .deny;
        return switch (trimmed[0]) {
            '1', 'y', 'Y' => .allow_once,
            '2', 'e', 'E' => .allow_session_exact,
            '3', 'a', 'A' => .allow_session_all,
            else => .deny,
        };
    }

    fn makeExactKey(arena_alloc: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) ![]u8 {
        var key = try arena_alloc.alloc(u8, tool_name.len + 1 + args_json.len);
        @memcpy(key[0..tool_name.len], tool_name);
        key[tool_name.len] = 0;
        @memcpy(key[tool_name.len + 1 ..], args_json);
        return key;
    }
};
