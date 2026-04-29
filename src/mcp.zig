//! Minimal Model Context Protocol (MCP) client.
//!
//! Spawns each configured MCP server as a child process, performs the
//! `initialize` handshake, lists available tools, and routes calls to
//! `mcp__<server>__<tool>` over the server's stdio. Only the `tools`
//! capability is supported in this build — `resources`, `prompts` and
//! `sampling` are out of scope. JSON-RPC 2.0 messages are exchanged as
//! newline-delimited JSON objects per the MCP stdio transport spec.

const std = @import("std");

const PROTOCOL_VERSION = "2025-06-18";
const QUALIFIED_PREFIX = "mcp__";
const SEP = "__";
const STARTUP_TIMEOUT_MS: u64 = 5_000;

pub fn isQualifiedName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, QUALIFIED_PREFIX);
}

pub const ToolDef = struct {
    server_name: []const u8, // owned by Server.arena
    qualified_name: []const u8, // owned by Server.arena
    raw_name: []const u8, // owned by Server.arena
    description: []const u8, // owned by Server.arena
    /// Pre-stringified JSON Schema. Owned by Server.arena.
    parameters_schema_json: []const u8,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    name: []const u8, // borrowed from arena
    child: std.process.Child,
    next_id: u64 = 1,
    initialized: bool = false,
    /// Read buffer for stdout reader. Sized for typical tool result payloads.
    read_buf: []u8,
    tool_defs: std.ArrayListUnmanaged(ToolDef) = .empty,

    pub fn deinit(self: *Server) void {
        // Best-effort graceful shutdown. The MCP spec recommends sending
        // a "shutdown" request followed by an "exit" notification, but
        // many real-world servers respond to closed stdin alone.
        if (self.child.stdin) |*stdin_file| {
            stdin_file.close();
            self.child.stdin = null;
        }
        _ = self.child.wait() catch {};
        self.allocator.free(self.read_buf);
        self.tool_defs.deinit(self.allocator);
        self.arena.deinit();
    }

    fn writeJson(self: *Server, json_line: []const u8) !void {
        const stdin = self.child.stdin orelse return error.ServerStdinClosed;
        try stdin.writeAll(json_line);
        if (json_line.len == 0 or json_line[json_line.len - 1] != '\n') {
            try stdin.writeAll("\n");
        }
    }

    fn nextId(self: *Server) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn sendRequest(
        self: *Server,
        method: []const u8,
        params_json_or_null: ?[]const u8,
    ) !u64 {
        const id = self.nextId();
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(id);
        try s.objectField("method");
        try s.write(method);
        if (params_json_or_null) |p| {
            try s.objectField("params");
            try s.beginWriteRaw();
            try buf.writer.writeAll(p);
            s.endWriteRaw();
        }
        try s.endObject();
        try self.writeJson(buf.writer.buffered());
        return id;
    }

    fn sendNotification(self: *Server, method: []const u8, params_json_or_null: ?[]const u8) !void {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("method");
        try s.write(method);
        if (params_json_or_null) |p| {
            try s.objectField("params");
            try s.beginWriteRaw();
            try buf.writer.writeAll(p);
            s.endWriteRaw();
        }
        try s.endObject();
        try self.writeJson(buf.writer.buffered());
    }

    /// Wait for a JSON-RPC response with `expected_id`. Notifications and
    /// non-matching responses are dropped silently. Returns the raw response
    /// JSON; caller frees.
    fn recvResponse(self: *Server, expected_id: u64) ![]u8 {
        const stdout = self.child.stdout orelse return error.ServerStdoutClosed;
        var reader = stdout.reader(self.read_buf);
        const r = &reader.interface;

        while (true) {
            const maybe = r.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => return error.McpFrameTooLong,
                else => return err,
            };
            const raw = maybe orelse return error.McpServerExited;
            const line = std.mem.trimRight(u8, raw, "\r");
            if (line.len == 0) continue;

            // Peek at id without fully owning the parsed tree's lifetime —
            // we only need the id to decide whether this response is ours.
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            const matches = blk: {
                if (parsed.value != .object) break :blk false;
                const id_v = parsed.value.object.get("id") orelse break :blk false;
                if (id_v != .integer) break :blk false;
                break :blk @as(u64, @intCast(id_v.integer)) == expected_id;
            };
            parsed.deinit();
            if (!matches) continue;

            return try self.allocator.dupe(u8, line);
        }
    }

    pub fn initialize(self: *Server) !void {
        const params =
            \\{"protocolVersion":"
        ++ PROTOCOL_VERSION ++
            \\","capabilities":{},"clientInfo":{"name":"agent-naokiman","version":"0.1"}}
        ;
        const id = try self.sendRequest("initialize", params);
        const resp = try self.recvResponse(id);
        defer self.allocator.free(resp);

        // Verify it's a successful response.
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("error")) |_| {
            return error.McpInitializeFailed;
        }

        try self.sendNotification("notifications/initialized", null);
        self.initialized = true;
    }

    /// Populate `self.tool_defs` from the server. All slices end up in the
    /// server's arena.
    pub fn fetchTools(self: *Server) !void {
        const id = try self.sendRequest("tools/list", null);
        const resp = try self.recvResponse(id);
        defer self.allocator.free(resp);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("error")) |_| return error.McpToolsListFailed;
        const result = parsed.value.object.get("result") orelse return error.McpToolsListMalformed;
        if (result != .object) return error.McpToolsListMalformed;
        const arr = result.object.get("tools") orelse return error.McpToolsListMalformed;
        if (arr != .array) return error.McpToolsListMalformed;

        const aa = self.arena.allocator();
        for (arr.array.items) |item| {
            if (item != .object) continue;
            const name_v = item.object.get("name") orelse continue;
            if (name_v != .string) continue;
            const desc_v = item.object.get("description");
            const schema_v = item.object.get("inputSchema");

            const desc: []const u8 = if (desc_v) |d| (if (d == .string) d.string else "") else "";
            const schema_str: []const u8 = if (schema_v) |s| try stringifyValue(aa, s) else "{\"type\":\"object\"}";

            const qualified = try std.fmt.allocPrint(aa, "{s}{s}{s}{s}", .{
                QUALIFIED_PREFIX, self.name, SEP, name_v.string,
            });

            try self.tool_defs.append(self.allocator, .{
                .server_name = self.name,
                .qualified_name = qualified,
                .raw_name = try aa.dupe(u8, name_v.string),
                .description = try aa.dupe(u8, desc),
                .parameters_schema_json = schema_str,
            });
        }
    }

    /// Invoke a tool by its raw (unqualified) name. Returns owned text.
    pub fn callTool(
        self: *Server,
        out_alloc: std.mem.Allocator,
        raw_name: []const u8,
        arguments_json: []const u8,
    ) ![]u8 {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        var s: std.json.Stringify = .{ .writer = &params.writer, .options = .{} };
        try s.beginObject();
        try s.objectField("name");
        try s.write(raw_name);
        try s.objectField("arguments");
        try s.beginWriteRaw();
        try params.writer.writeAll(arguments_json);
        s.endWriteRaw();
        try s.endObject();

        const id = try self.sendRequest("tools/call", params.writer.buffered());
        const resp = try self.recvResponse(id);
        defer self.allocator.free(resp);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("error")) |e| {
            return try std.fmt.allocPrint(out_alloc, "error: MCP server returned error: {s}", .{
                if (e == .object) blk: {
                    if (e.object.get("message")) |m| {
                        if (m == .string) break :blk m.string;
                    }
                    break :blk "(unknown)";
                } else "(unknown)",
            });
        }

        const result = parsed.value.object.get("result") orelse return error.McpCallMalformed;
        if (result != .object) return error.McpCallMalformed;

        // MCP returns content: [{type:"text", text:"..."}]. Concatenate text
        // entries; for non-text entries emit a placeholder.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(out_alloc);
        if (result.object.get("content")) |c| {
            if (c == .array) {
                for (c.array.items) |entry| {
                    if (entry != .object) continue;
                    const t_v = entry.object.get("type") orelse continue;
                    if (t_v != .string) continue;
                    if (std.mem.eql(u8, t_v.string, "text")) {
                        if (entry.object.get("text")) |txt| {
                            if (txt == .string) try out.appendSlice(out_alloc, txt.string);
                        }
                    } else {
                        try out.writer(out_alloc).print("[mcp:{s} content omitted]", .{t_v.string});
                    }
                }
            }
        }
        if (result.object.get("isError")) |ie| {
            if (ie == .bool and ie.bool) {
                const wrapped = try std.fmt.allocPrint(out_alloc, "tool error: {s}", .{out.items});
                return wrapped;
            }
        }
        return try out.toOwnedSlice(out_alloc);
    }
};

/// Re-stringify a parsed JSON value back into a JSON text. Used to capture
/// tool inputSchema verbatim into long-lived storage.
fn stringifyValue(allocator: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(v, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub const Manager = struct {
    allocator: std.mem.Allocator,
    servers: std.ArrayListUnmanaged(*Server) = .empty,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        for (self.servers.items) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.servers.deinit(self.allocator);
    }

    /// Load and start every server defined in `~/.config/agent-naokiman/mcp.json`.
    /// Missing or empty config file is not an error — manager just stays empty.
    pub fn loadConfig(self: *Manager, config_dir: []const u8) !void {
        const path = try std.fs.path.join(self.allocator, &.{ config_dir, "mcp.json" });
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0 or stat.size > 1 * 1024 * 1024) return;

        const body = try self.allocator.alloc(u8, @intCast(stat.size));
        defer self.allocator.free(body);
        _ = try file.readAll(body);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch |err| {
            std.debug.print("warning: invalid mcp.json: {s}\n", .{@errorName(err)});
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const servers_obj = parsed.value.object.get("mcpServers") orelse return;
        if (servers_obj != .object) return;

        var it = servers_obj.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (val != .object) continue;
            self.spawnFromValue(name, val) catch |err| {
                std.debug.print("warning: failed to start MCP server '{s}': {s}\n", .{ name, @errorName(err) });
            };
        }
    }

    fn spawnFromValue(self: *Manager, name: []const u8, v: std.json.Value) !void {
        const cmd_v = v.object.get("command") orelse return error.McpConfigMissingCommand;
        if (cmd_v != .string) return error.McpConfigBadCommand;

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, cmd_v.string);
        if (v.object.get("args")) |args_v| {
            if (args_v == .array) {
                for (args_v.array.items) |a| {
                    if (a == .string) try argv.append(self.allocator, a.string);
                }
            }
        }

        const server = try self.allocator.create(Server);
        errdefer self.allocator.destroy(server);

        server.* = .{
            .allocator = self.allocator,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .name = "",
            .child = std.process.Child.init(argv.items, self.allocator),
            .read_buf = try self.allocator.alloc(u8, 256 * 1024),
        };
        errdefer {
            self.allocator.free(server.read_buf);
            server.arena.deinit();
        }

        // Move server name into arena so it outlives the parsed config.
        server.name = try server.arena.allocator().dupe(u8, name);

        server.child.stdin_behavior = .Pipe;
        server.child.stdout_behavior = .Pipe;
        server.child.stderr_behavior = .Inherit; // surface stderr for debugging

        try server.child.spawn();

        try server.initialize();
        try server.fetchTools();

        try self.servers.append(self.allocator, server);
    }

    /// Append every server's tools as function objects inside an already-open
    /// JSON array. The caller owns `beginArray` / `endArray`.
    pub fn appendToolsToArray(self: *const Manager, s: *std.json.Stringify, out: *std.Io.Writer) !void {
        for (self.servers.items) |srv| {
            for (srv.tool_defs.items) |t| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("function");
                try s.objectField("function");
                try s.beginObject();
                try s.objectField("name");
                try s.write(t.qualified_name);
                try s.objectField("description");
                try s.write(t.description);
                try s.objectField("parameters");
                try s.beginWriteRaw();
                try out.writeAll(t.parameters_schema_json);
                s.endWriteRaw();
                try s.endObject();
                try s.endObject();
            }
        }
    }

    pub fn hasAny(self: *const Manager) bool {
        for (self.servers.items) |srv| {
            if (srv.tool_defs.items.len > 0) return true;
        }
        return false;
    }

    /// Returns null if `qualified_name` does not belong to any MCP server.
    /// Otherwise returns owned tool result text.
    pub fn execute(
        self: *Manager,
        out_alloc: std.mem.Allocator,
        qualified_name: []const u8,
        arguments_json: []const u8,
    ) !?[]u8 {
        if (!isQualifiedName(qualified_name)) return null;
        // Strip prefix and split <server> "__" <tool>.
        const without_prefix = qualified_name[QUALIFIED_PREFIX.len..];
        const sep_idx = std.mem.indexOf(u8, without_prefix, SEP) orelse return null;
        const server_name = without_prefix[0..sep_idx];
        const raw_name = without_prefix[sep_idx + SEP.len ..];

        for (self.servers.items) |srv| {
            if (!std.mem.eql(u8, srv.name, server_name)) continue;
            return try srv.callTool(out_alloc, raw_name, arguments_json);
        }
        return try std.fmt.allocPrint(out_alloc, "error: no MCP server named '{s}' is loaded", .{server_name});
    }

    /// Return a list of {qualified_name, server_name} pairs for display.
    pub fn summarize(self: *const Manager, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var count: usize = 0;
        for (self.servers.items) |srv| {
            for (srv.tool_defs.items) |t| {
                try out.writer.print("  {s}\n", .{t.qualified_name});
                count += 1;
            }
        }
        if (count == 0) try out.writer.writeAll("  (no MCP tools loaded)\n");
        return out.toOwnedSlice();
    }
};
