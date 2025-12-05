const num_tasks = 25;

pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);
    const env = try std.process.getEnvMap(arena);

    const process_index = try std.fmt.parseInt(usize, args[1], 10);

    var job_client: std.job.Client = try .init(arena, &env);
    defer job_client.deinit();

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = arena, .job_client = &job_client });
    defer thread_pool.deinit();

    // Spawn a bunch of tasks with a variable amount of CPU-intensive work
    var rng: std.Random.DefaultPrng = .init(process_index);
    const r = rng.random();
    for (0..num_tasks) |_| {
        try thread_pool.spawn(doWork, .{ process_index, r.intRangeAtMost(u32, 300_000, 1_000_000) });
    }
}

fn doWork(
    process_index: usize,
    work_amount: u32,
) void {
    std.log.info("[process {d}] start", .{process_index});
    defer std.log.info("[process {d}] stop", .{process_index});

    // Badly simulate single-threaded CPU-intensive work
    for (0..work_amount) |_| {
        for (0..1000) |_| asm volatile ("nop");
    }
}

const std = @import("std");
