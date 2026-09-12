const std = @import("std");
const garbage_collector = @import("garbage_collector");

pub fn main() void {}

test "ref decls" {
    _ = std.testing.refAllDecls(garbage_collector.State);
}

test "demo" {
    const size = 100;

    var gc: garbage_collector.State = .init(std.testing.allocator, 1);
    defer gc.deinit();

    const a = gc.allocator();

    for (0..size) |i| {
        const alloc = try a.alloc(i32, i);
        defer a.free(alloc); // optional
        for (alloc) |*n| {
            n.* = @intCast(i);
        }
    }
}

test "pinning" {
    var gc: garbage_collector.State = .init(std.testing.allocator, 1);
    defer gc.deinit();

    const a = gc.allocator();

    const mem = try a.alloc(i32, 10);
    gc.pin(mem);
    try gc.collect();
    gc.unpin(mem);
    try gc.collect();
}

fn testBurnStack(depth: u32) void {
    if (depth == 0) return;
    var junk: [512]u8 = undefined;
    for (&junk, 0..) |*b, i| {
        b.* = @truncate(i +% depth);
    }
    std.mem.doNotOptimizeAway(&junk);
    testBurnStack(depth - 1);
}

test "unreachable allocations collected" {
    var gc: garbage_collector.State = .init(std.testing.allocator, 1 << 30);
    defer gc.deinit();

    const a = gc.allocator();
    const garbage = try a.create(u64);
    garbage.* = 0xDEAD;
    const garbage_ptr: [*]const u8 = @ptrCast(garbage);

    testBurnStack(64);
    try gc.collect();

    try std.testing.expect(!gc.allocations.contains(garbage_ptr));
}

test "pinned parent, child survives" {
    var gc: garbage_collector.State = .init(std.testing.allocator, 1 << 30);
    defer gc.deinit();

    const a = gc.allocator();
    const Node = struct { child: ?*u64 = null };

    const child = try a.create(u64);
    child.* = 0x1234;
    const parent = try a.create(Node);
    parent.* = .{ .child = child };
    gc.pin(parent);

    const child_ptr: [*]const u8 = @ptrCast(child);

    testBurnStack(64);
    try gc.collect();

    try std.testing.expect(gc.allocations.contains(child_ptr));
    try std.testing.expectEqual(@as(u64, 0x1234), child.*);
}

test "multi-levell chain" {
    var gc: garbage_collector.State = .init(std.testing.allocator, 1 << 30);
    defer gc.deinit();

    const a = gc.allocator();
    const Node = struct {
        next: ?*Self = null,
        tag: u32 = 0,

        const Self = @This();
    };

    const head = try a.create(Node);
    head.* = .{
        .tag = 0,
    };
    var cur = head;
    var i: u32 = 1;
    while (i <= 10) : (i += 1) {
        const n = try a.create(Node);
        n.* = .{ .tag = i };
        cur.next = n;
        cur = n;
    }
    gc.pin(head);
    const tail_ptr: [*]const u8 = @ptrCast(cur);

    testBurnStack(64);
    try gc.collect();

    try std.testing.expect(gc.allocations.contains(tail_ptr));
    try std.testing.expectEqual(@as(u32, 10), cur.tag);
}

test "pinning survival" {
    var gc: garbage_collector.State = .init(std.testing.allocator, 1 << 30);
    defer gc.deinit();

    const a = gc.allocator();
    const obj = try a.create(u64);
    obj.* = 42;
    gc.pin(obj);
    const ptr: [*]const u8 = @ptrCast(obj);

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        testBurnStack(32);
        try gc.collect();
        try std.testing.expect(gc.allocations.contains(ptr));
    }
    try std.testing.expectEqual(@as(u64, 42), obj.*);
}

test "pin to unpin" {
    var gc: garbage_collector.State = .init(std.testing.allocator, 1 << 30);
    defer gc.deinit();

    const a = gc.allocator();
    const obj = try a.create(u64);
    obj.* = 7;
    const ptr: [*]const u8 = @ptrCast(obj);

    gc.pin(obj);
    testBurnStack(32);
    try gc.collect();
    try std.testing.expect(gc.allocations.contains(ptr));

    gc.unpin(obj);
    testBurnStack(32);
    try gc.collect();
    try std.testing.expect(!gc.allocations.contains(ptr));
}

var test_global_root: ?*u64 = null;

test "global reference" {
    var gc: garbage_collector.State = .init(std.testing.allocator, 1 << 30);
    defer gc.deinit();

    const a = gc.allocator();
    const obj = try a.create(u64);
    obj.* = 99;
    test_global_root = obj;
    defer test_global_root = null;

    const ptr: [*]const u8 = @ptrCast(obj);

    testBurnStack(64);
    try gc.collect();

    try std.testing.expect(gc.allocations.contains(ptr));
}

test "live bytes accuracy" {
    var gc: garbage_collector.State = .init(std.testing.allocator, 1 << 30);
    defer gc.deinit();

    const a = gc.allocator();
    const kept = try a.create(u64);
    gc.pin(kept);
    _ = try a.create(u64); // garbage, no pin, no other reference

    testBurnStack(64);
    try gc.collect();

    try std.testing.expectEqual(@as(u64, 1), gc.allocations.count());
    try std.testing.expectEqual(@as(u64, @sizeOf(u64)), gc.live_bytes);
}
