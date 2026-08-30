const std = @import("std");
const garbage_collector = @import("garbage_collector");

pub fn main() void {}

test "ref decls" {
    _ = std.testing.refAllDecls(garbage_collector.State);
}

test "demo" {
    const size = 100;

    var gc: garbage_collector.State = .init(std.testing.allocator, 1);
    const gpa = gc.allocator();
    defer gc.deinit();

    for (0..size) |i| {
        const alloc = try gpa.alloc(i32, i);
        defer gpa.free(alloc); // optional
        for (alloc) |*n| {
            n.* = @intCast(i);
        }
    }
}
