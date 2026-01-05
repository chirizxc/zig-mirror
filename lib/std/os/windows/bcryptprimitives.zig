const std = @import("../../std.zig");
const windows = std.os.windows;

pub extern "bcryptprimitives" fn ProcessPrng(pbData: [*]u8, cbData: usize) callconv(.winapi) c_int;
