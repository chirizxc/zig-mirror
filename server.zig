const num_children = 25;

pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const cpu_count = try std.Thread.getCpuCount();
    var env = try std.process.getEnvMap(arena);

    var job_server: std.job.Server = try .init(arena, @intCast(cpu_count), &env);
    defer job_server.deinit();

    var children: [num_children]std.process.Child = undefined;
    for (&children, 0..) |*c, child_num| {
        const child_num_str = try std.fmt.allocPrint(arena, "{d}", .{child_num});
        const argv = try arena.dupe([]const u8, &.{ switch (builtin.os.tag) {
            else => "./worker",
            .windows => ".\\worker.exe",
        }, child_num_str });
        c.* = .init(argv, arena);
        c.env_map = &env;
    }

    std.log.info("Spawning {d} workers on {d} CPUs", .{ children.len, cpu_count });
    for (&children) |*c| try c.spawn();
    for (&children) |*c| _ = try c.wait();
    std.log.info("All {d} workers exited", .{children.len});
}

const builtin = @import("builtin");
const std = @import("std");
