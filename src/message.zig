const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,

    pub fn asStr(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
        };
    }
};

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const History = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayListUnmanaged(Message) = .empty,

    pub fn init(parent: std.mem.Allocator) History {
        return .{ .arena = std.heap.ArenaAllocator.init(parent) };
    }

    pub fn deinit(self: *History) void {
        self.arena.deinit();
    }

    pub fn clear(self: *History) void {
        _ = self.arena.reset(.retain_capacity);
        self.items = .empty;
    }

    pub fn append(self: *History, role: Role, content: []const u8) !void {
        const a = self.arena.allocator();
        const owned = try a.dupe(u8, content);
        try self.items.append(a, .{ .role = role, .content = owned });
    }
};

/// Serialize a History into a JSON body suitable for OpenAI-compatible
/// /chat/completions endpoints. Caller owns nothing — `out` is written to.
pub fn writeChatRequest(
    out: *std.Io.Writer,
    model: []const u8,
    history: *const History,
    stream: bool,
) !void {
    var s: std.json.Stringify = .{ .writer = out, .options = .{} };
    try s.beginObject();
    try s.objectField("model");
    try s.write(model);
    try s.objectField("stream");
    try s.write(stream);
    try s.objectField("messages");
    try s.beginArray();
    for (history.items.items) |m| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role.asStr());
        try s.objectField("content");
        try s.write(m.content);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}
