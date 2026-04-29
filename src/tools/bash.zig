const std = @import("std");
const mod = @import("mod.zig");

pub const tool: mod.Tool = .{
    .name = "bash",
    .description =
    \\Run a shell command via /bin/sh -c. Returns the combined stdout, stderr,
    \\and exit status as a single string. Use this when you need to inspect
    \\the filesystem, run build/test commands, search code, etc. The command
    \\inherits the agent's current working directory.
    \\
    \\WARNING: this runs commands directly with no confirmation. Avoid
    \\destructive operations (rm -rf, drop database, etc.) without asking the
    \\user first.
    ,
    .parameters_schema_json =
    \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to run, e.g. \"ls -la src\" or \"grep -rn TODO .\"."}},"required":["command"],"additionalProperties":false}
    ,
    .execute = execute,
};

const MAX_OUTPUT: usize = 64 * 1024;

fn execute(allocator: std.mem.Allocator, args_json: []const u8) anyerror![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to parse arguments JSON ({s})", .{@errorName(err)});
    };
    defer parsed.deinit();

    const cmd_val = parsed.value.object.get("command") orelse {
        return try allocator.dupe(u8, "error: missing required argument 'command'");
    };
    if (cmd_val != .string) {
        return try allocator.dupe(u8, "error: argument 'command' must be a string");
    }
    const cmd = cmd_val.string;

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = MAX_OUTPUT,
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to spawn shell: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_str = switch (result.term) {
        .Exited => |c| try std.fmt.allocPrint(allocator, "exited({d})", .{c}),
        .Signal => |s| try std.fmt.allocPrint(allocator, "signal({d})", .{s}),
        .Stopped => |s| try std.fmt.allocPrint(allocator, "stopped({d})", .{s}),
        .Unknown => |s| try std.fmt.allocPrint(allocator, "unknown({d})", .{s}),
    };
    defer allocator.free(exit_str);

    return std.fmt.allocPrint(
        allocator,
        "[exit: {s}]\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
        .{ exit_str, result.stdout, result.stderr },
    );
}
