//! This namespace provides an implementation of the Robust Jobserver protocol:
//! https://codeberg.org/mlugg/robust-jobserver/
//!
//! `Client` and `Server` currently both support the `sysvsem` and `win32pipe`
//! communication methods, meaning this implementation is usable on most POSIX
//! targets and on Windows.

pub const Client = @import("job/Client.zig");
pub const Server = @import("job/Server.zig");

pub const Method = enum { sysvsem, win32pipe };

pub const sysv_sem = struct {
    pub const supported = switch (builtin.os.tag) {
        .linux,
        .illumos,
        .haiku,

        .freebsd,
        .netbsd,
        .openbsd,
        .dragonfly,

        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => true,

        else => false,
    };

    /// `semget(IPC_PRIVATE, 1, 0o777)`
    pub fn create() error{ SystemResources, Unexpected }!i32 {
        const res = system.create();
        switch (std.posix.errno(res)) {
            .SUCCESS => return @intCast(res),
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.SystemResources,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }
    /// `semctl(id, 0, SETVAL, n)`
    pub fn setValue(id: i32, n: u32) error{Unexpected}!void {
        switch (std.posix.errno(system.setValue(id, n))) {
            .SUCCESS => return,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }
    /// `semop(id, &.{.{ .sem_num = 0, .sem_op = delta, .sem_flg = SEM_UNDO }})`
    pub fn modify(id: i32, delta: i16) error{
        InvalidSemaphore,
        AccessDenied,
        SystemResources,
        /// A signal interrupted a blocked call to `modify`.
        /// This allows the caller to implement cancelation.
        Interrupted,
        Unexpected,
    }!void {
        while (true) {
            switch (std.posix.errno(system.modify(id, delta))) {
                .SUCCESS => return,
                .ACCES => return error.AccessDenied,
                .FBIG => return error.InvalidSemaphore,
                .IDRM => return error.InvalidSemaphore,
                .INTR => return error.Interrupted,
                .INVAL => return error.InvalidSemaphore,
                .NOMEM => return error.SystemResources,
                .RANGE => return error.InvalidSemaphore,
                else => |e| return std.posix.unexpectedErrno(e),
            }
        }
    }

    const system = if (builtin.link_libc) struct {
        fn create() c_int {
            return std.c.semget(.IPC_PRIVATE, 1, 0o777);
        }
        fn setValue(id: i32, n: u32) c_int {
            return std.c.semctl(id, 0, std.posix.SETVAL, n);
        }
        fn modify(id: i32, delta: i16) c_int {
            var ops: [1]std.posix.sembuf = .{.{
                .sem_num = 0,
                .sem_op = delta,
                .sem_flg = std.posix.SEM_UNDO,
            }};
            return std.c.semop(id, &ops, ops.len);
        }
    } else switch (builtin.os.tag) {
        .linux => struct {
            fn create() usize {
                const key: std.posix.key_t = .IPC_PRIVATE;
                return std.os.linux.syscall3(.semget, @intFromEnum(key), 1, 0o777);
            }
            fn setValue(id: i32, n: u32) usize {
                return std.os.linux.syscall4(.semctl, @intCast(id), 0, std.posix.SETVAL, n);
            }
            fn modify(id: i32, delta: i16) usize {
                var ops: [1]std.posix.sembuf = .{.{
                    .sem_num = 0,
                    .sem_op = delta,
                    .sem_flg = std.posix.SEM_UNDO,
                }};
                return std.os.linux.syscall3(.semop, @intCast(id), @intFromPtr(&ops), ops.len);
            }
        },
        else => unreachable,
    };
};

const builtin = @import("builtin");
const std = @import("std.zig");
