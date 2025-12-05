/// `null` means we are inheriting a jobserver instance from a parent process.
impl: ?Impl,

pub const InitError = error{ OutOfMemory, SystemResources, Unexpected };
pub fn init(arena: Allocator, job_limit: u32, env: *std.process.EnvMap) InitError!Server {
    assert(job_limit > 0);
    if (env.get("ROBUST_JOBSERVER") != null) {
        return .{ .impl = null };
    }
    const method: job.Method = switch (builtin.target.os.tag) {
        .windows => .win32pipe,
        else => .sysvsem,
    };
    const impl: @FieldType(Impl, @tagName(method)) = try .init(arena, job_limit);
    const env_val = try std.fmt.allocPrint(arena, "{t}:{f}", .{ method, std.fmt.alt(impl, .formatEnvData) });
    try env.put("ROBUST_JOBSERVER", env_val);
    return .{ .impl = @unionInit(Impl, @tagName(method), impl) };
}
pub fn deinit(s: *Server) void {
    if (s.impl) |*impl| {
        switch (impl.*) {
            inline else => |*x| x.deinit(),
        }
    }
    s.* = undefined;
}

const Impl = union(job.Method) {
    sysvsem: if (job.sysv_sem.supported) SysVSem else noreturn,
    win32pipe: if (builtin.target.os.tag == .windows) Win32Pipe else noreturn,
};

const SysVSem = struct {
    set_id: i32,
    fn init(arena: Allocator, num_tokens: u32) InitError!SysVSem {
        _ = arena;
        const id = try job.sysv_sem.create();
        try job.sysv_sem.setValue(id, num_tokens);
        return .{ .set_id = id };
    }
    fn deinit(sem: SysVSem) void {
        _ = sem;
    }
    pub fn formatEnvData(sem: SysVSem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}", .{sem.set_id});
    }
};

const Win32Pipe = struct {
    pipe_name: []const u8,
    done_event: windows.HANDLE,
    thread: std.Thread,

    const Token = struct {
        handle: windows.HANDLE,
        iosb: windows.IO_STATUS_BLOCK,
        dummy_read_buf: [1]u8,
    };

    var pipe_name_counter: std.atomic.Value(u32) = .init(0);
    fn init(arena: Allocator, num_tokens: u32) InitError!Win32Pipe {
        const pipe_name = try std.fmt.allocPrint(arena, "zig-jobserver-{d}-{x}", .{
            windows.GetCurrentProcessId(),
            std.crypto.random.int(u64),
        });

        const nt_path = std.unicode.wtf8ToWtf16LeAllocZ(
            arena,
            try std.fmt.allocPrint(arena, "\\??\\pipe\\{s}", .{pipe_name}),
        ) catch |err| switch (err) {
            error.InvalidWtf8 => unreachable,
            error.OutOfMemory => |e| return e,
        };

        const tokens = try arena.alloc(Token, num_tokens);
        @memset(tokens, .{
            .handle = windows.INVALID_HANDLE_VALUE,
            .iosb = undefined,
            .dummy_read_buf = undefined,
        });
        errdefer for (tokens) |*token| {
            if (token.handle != windows.INVALID_HANDLE_VALUE) {
                _ = windows.ntdll.NtClose(token.handle);
            }
        };

        for (tokens) |*t| {
            var path: windows.UNICODE_STRING = .{
                .Buffer = nt_path.ptr,
                .Length = @intCast(@sizeOf(u16) * nt_path.len),
                .MaximumLength = 0,
            };
            var iosb: windows.IO_STATUS_BLOCK = undefined;
            switch (windows.ntdll.NtCreateNamedPipeFile(
                &t.handle,
                .{ .GENERIC = .{ .READ = true } },
                &.{
                    .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
                    .RootDirectory = null,
                    .ObjectName = &path,
                    .Attributes = .{},
                    .SecurityDescriptor = null,
                    .SecurityQualityOfService = null,
                },
                &iosb,
                .{ .WRITE = true },
                .OPEN_IF,
                .{ .IO = .ASYNCHRONOUS },
                .{ .TYPE = .BYTE_STREAM },
                .{ .MODE = .BYTE_STREAM },
                .{ .OPERATION = .QUEUE },
                @intCast(num_tokens),
                0,
                0,
                &((-120 * std.time.ns_per_s) / 100),
            )) {
                .SUCCESS => {},
                .INSUFFICIENT_RESOURCES => return error.SystemResources,
                else => |e| return windows.unexpectedStatus(e),
            }
        }

        var done_event: windows.HANDLE = undefined;
        switch (windows.ntdll.NtCreateEvent(
            &done_event,
            windows.ACCESS_MASK.Specific.Event.ALL_ACCESS,
            null,
            .Notification,
            windows.FALSE,
        )) {
            .SUCCESS => {},
            .INSUFFICIENT_RESOURCES => return error.SystemResources,
            else => |e| return windows.unexpectedStatus(e),
        }
        errdefer _ = windows.ntdll.NtClose(done_event);

        const thread = std.Thread.spawn(.{}, serve, .{ tokens, done_event }) catch |err| switch (err) {
            error.SystemResources,
            error.Unexpected,
            error.OutOfMemory,
            => |e| return e,

            error.ThreadQuotaExceeded,
            error.LockedMemoryLimitExceeded,
            => return error.SystemResources,
        };
        errdefer comptime unreachable; // the thread is now running and owns `tokens`

        return .{
            .pipe_name = pipe_name,
            .done_event = done_event,
            .thread = thread,
        };
    }
    fn deinit(wp: *const Win32Pipe) void {
        _ = windows.ntdll.NtSetEvent(wp.done_event, null);
        wp.thread.join();
        _ = windows.ntdll.NtClose(wp.done_event);
    }
    pub fn formatEnvData(wp: Win32Pipe, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(wp.pipe_name);
    }

    fn serve(tokens: []Token, done_event: windows.HANDLE) void {
        defer {
            for (tokens) |*token| {
                _ = windows.ntdll.NtClose(token.handle);
            }
        }

        for (tokens) |*t| serveToken(t, .connect);

        while (true) {
            switch (windows.ntdll.NtWaitForSingleObject(
                done_event,
                windows.TRUE,
                null,
            )) {
                windows.NTSTATUS.ABANDONED_WAIT_0 => unreachable, // not a mutex
                .USER_APC => continue,
                windows.NTSTATUS.WAIT_0 => break,
                .TIMEOUT => unreachable, // no timeout
                else => |e| std.debug.panic("unexpected NTSTATUS=0x{x} in job server", .{@intFromEnum(e)}),
            }
        }
    }
    const Action = enum { connect, read, disconnect };
    fn serveToken(token: *Token, first_action: Action) void {
        action: switch (first_action) {
            .connect => if (windows.DeviceIoControl(token.handle, windows.FSCTL.PIPE.LISTEN, .{
                .apc_routine = &connectCompleted,
                .apc_context = token,
                .io_status_block = &token.iosb,
            })) |_| {
                return; // The APC has been queued and will continue the loop.
            } else |err| switch (err) {
                error.AccessDenied => unreachable, // we created the pipe
                error.UnrecognizedVolume => unreachable, // it's not a volume
                error.Pending => return,
                error.PipeClosing => continue :action .disconnect,
                error.PipeAlreadyConnected => continue :action .read,
                error.PipeAlreadyListening => unreachable, // pipe is not in nonblocking mode
                error.Unexpected => @panic("unexpected error in job server"),
            },
            .read => switch (windows.ntdll.NtReadFile(
                token.handle,
                null,
                &readCompleted,
                token,
                &token.iosb,
                &token.dummy_read_buf,
                token.dummy_read_buf.len,
                null,
                null,
            )) {
                .PENDING => return,
                .PIPE_BROKEN => continue :action .disconnect,
                .SUCCESS => {
                    // The client isn't meant to write to the pipe---disconnect them as punishment.
                    return; // The APC has been queued and will do that for us.
                },
                else => |e| std.debug.panic("unexpected NTSTATUS=0x{x} in job server", .{@intFromEnum(e)}),
            },
            .disconnect => if (windows.DeviceIoControl(token.handle, windows.FSCTL.PIPE.DISCONNECT, .{
                .apc_routine = &disconnectCompleted,
                .apc_context = token,
                .io_status_block = &token.iosb,
            })) |_| {
                return; // The APC has been queued and will continue the loop.
            } else |err| switch (err) {
                error.AccessDenied => unreachable, // we created the pipe
                error.UnrecognizedVolume => unreachable, // it's not a volume
                error.Pending => return,
                error.PipeClosing => unreachable,
                error.PipeAlreadyConnected => unreachable,
                error.PipeAlreadyListening => unreachable,
                error.Unexpected => @panic("unexpected error in job server"),
            },
        }
    }
    fn connectCompleted(
        ctx: ?*anyopaque,
        iosb: *windows.IO_STATUS_BLOCK,
        _: windows.ULONG,
    ) callconv(.winapi) void {
        serveToken(@ptrCast(@alignCast(ctx)), switch (iosb.u.Status) {
            .SUCCESS, .PIPE_CONNECTED => .read,
            .PIPE_CLOSING => .disconnect,
            else => |e| std.debug.panic("unexpected NTSTATUS=0x{x} in job server", .{@intFromEnum(e)}),
        });
    }
    fn readCompleted(
        ctx: ?*anyopaque,
        iosb: *windows.IO_STATUS_BLOCK,
        _: windows.ULONG,
    ) callconv(.winapi) void {
        serveToken(@ptrCast(@alignCast(ctx)), switch (iosb.u.Status) {
            .SUCCESS, .PIPE_BROKEN => .disconnect,
            else => |e| std.debug.panic("unexpected NTSTATUS=0x{x} in job server", .{@intFromEnum(e)}),
        });
    }
    fn disconnectCompleted(
        ctx: ?*anyopaque,
        iosb: *windows.IO_STATUS_BLOCK,
        _: windows.ULONG,
    ) callconv(.winapi) void {
        serveToken(@ptrCast(@alignCast(ctx)), switch (iosb.u.Status) {
            .SUCCESS => .connect,
            else => |e| std.debug.panic("unexpected NTSTATUS=0x{x} in job server", .{@intFromEnum(e)}),
        });
    }
};

const builtin = @import("builtin");

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const job = std.job;
const windows = std.os.windows;

const Server = @This();
