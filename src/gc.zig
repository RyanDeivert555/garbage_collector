const std = @import("std");
const builtin = @import("builtin");
const internals = @import("internals.zig");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const VTable = Allocator.VTable;
const AllocError = Allocator.Error;

pub const Flag = enum {
    // unscanned allocation
    unmarked,
    // reachable allocation, to be able to survive collection
    marked,
};

pub const Allocation = struct {
    memory: []u8,
    alignment: Alignment,
    flag: Flag,
    pinned: bool,
};

const AllocationMap = std.AutoHashMapUnmanaged([*]const u8, Allocation);

fn markAddress(gc: *State, base: [*]const u8) void {
    const allocation = gc.allocations.getPtr(base) orelse return;
    std.debug.assert(base == allocation.memory.ptr);

    if (allocation.flag == .marked) {
        return;
    }

    allocation.flag = .marked;
    markAddressRange(gc, allocation.memory);
}

fn markAddressRange(gc: *State, memory: []const u8) void {
    const start = std.mem.alignForward(usize, @intFromPtr(memory.ptr), @alignOf(usize));
    const end = std.mem.alignBackward(usize, @intFromPtr(memory.ptr + memory.len), @alignOf(usize));

    var addr = start;
    while (addr < end) : (addr += @sizeOf(usize)) {
        const slot: *const usize = @ptrFromInt(addr);
        const referenced_addr = slot.*;
        if (referenced_addr == 0) {
            continue;
        }

        markAddress(gc, @ptrFromInt(referenced_addr));
    }
}

fn markPinned(gc: *State) void {
    var it = gc.allocations.valueIterator();

    while (it.next()) |allocation| {
        if (allocation.pinned) {
            markAddress(gc, allocation.memory.ptr);
        }
    }
}

fn markStack(gc: *State) void {
    const stack_frame = @frameAddress();

    if (gc.stack_ptr > stack_frame) {
        const memory_start: [*]const u8 = @ptrFromInt(stack_frame);
        const len = gc.stack_ptr - stack_frame;
        const memory = memory_start[0..len];

        markAddressRange(gc, memory);
    } else {
        const memory_start: [*]const u8 = @ptrFromInt(gc.stack_ptr);
        const len = stack_frame - gc.stack_ptr;
        const memory = memory_start[0..len];

        markAddressRange(gc, memory);
    }
}

fn markGlobals(gc: *State) AllocError!void {
    const ranges = try switch (builtin.target.os.tag) {
        .linux => internals.linux.getGlobalSections(gc.child_allocator),
        .windows => internals.windows.getGlobalSections(gc.child_allocator),
        else => @compileError("os " ++ @tagName(builtin.target.os.tag) ++ " not supported"),
    };
    defer gc.child_allocator.free(ranges);

    for (ranges) |range| {
        const start, const end = range;
        const len = end - start;
        const memory_start: [*]u8 = @ptrFromInt(start);
        const memory = memory_start[0..len];

        markAddressRange(gc, memory);
    }
}

fn mark(gc: *State) AllocError!void {
    markPinned(gc);
    markStack(gc);
    try markGlobals(gc);
}

fn sweep(gc: *State) AllocError!void {
    const potential_frees = try gc.child_allocator.alloc([*]const u8, gc.allocations.count());
    defer gc.child_allocator.free(potential_frees);
    var potential_free_count: usize = 0;

    var it = gc.allocations.valueIterator();
    while (it.next()) |allocation| {
        if (allocation.flag == .unmarked and !allocation.pinned) {
            potential_frees[potential_free_count] = allocation.memory.ptr;
            potential_free_count += 1;
        } else if (allocation.flag == .marked) {
            allocation.flag = .unmarked;
        }
    }

    for (potential_frees) |memory| {
        const res = gc.allocations.fetchRemove(memory) orelse continue;
        const allocation = res.value;
        gc.live_bytes -= allocation.memory.len;
        gc.child_allocator.rawFree(allocation.memory, allocation.alignment, @returnAddress());
    }

    computeSweepLimit(gc);
}

fn computeSweepLimit(gc: *State) void {
    const growth_factor = 2;
    const floor_bytes = 1 << 20;
    const target = gc.live_bytes * growth_factor;
    gc.sweep_limit = @max(target, floor_bytes);
}

fn resetAllMarked(gc: *State) void {
    var it = gc.allocations.valueIterator();
    while (it.next()) |allocation| {
        if (allocation.flag == .marked) {
            allocation.flag = .unmarked;
        }
    }
}

pub const State = struct {
    allocations: AllocationMap,
    stack_ptr: usize,
    child_allocator: Allocator,
    sweep_limit: u64,
    live_bytes: u64,

    const vtable: VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    pub fn init(child_allocator: Allocator, sweep_limit: u64) State {
        return .{
            .allocations = .empty,
            .stack_ptr = @frameAddress(),
            .child_allocator = child_allocator,
            .sweep_limit = sweep_limit,
            .live_bytes = 0,
        };
    }

    pub fn deinit(self: *State) void {
        var it = self.allocations.valueIterator();
        while (it.next()) |allocation| {
            const slice = allocation.memory;

            self.child_allocator.rawFree(slice, allocation.alignment, @returnAddress());
        }

        self.allocations.deinit(self.child_allocator);
    }

    pub fn rawAlloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *State = @ptrCast(@alignCast(ptr));

        if (self.live_bytes > self.sweep_limit) {
            self.collect() catch return null;
        }

        const base = self.child_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        const memory = base[0..len];
        self.allocations.put(self.child_allocator, base, .{
            .memory = memory,
            .alignment = alignment,
            .flag = .unmarked,
            .pinned = false,
        }) catch {
            self.child_allocator.rawFree(memory, alignment, ret_addr);
            return null;
        };

        self.live_bytes += len;

        return base;
    }

    pub const rawResize = Allocator.noResize;
    pub const rawRemap = Allocator.noRemap;
    pub const rawFree = Allocator.noFree;

    pub fn allocator(self: *State) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn pin(self: *State, base: anytype) void {
        const raw_bytes: [*]const u8 = @ptrCast(@alignCast(base));

        const allocation = self.allocations.getPtr(raw_bytes) orelse return;
        allocation.pinned = true;
    }

    pub fn unpin(self: *State, base: anytype) void {
        const raw_bytes: [*]const u8 = @ptrCast(@alignCast(base));

        const allocation = self.allocations.getPtr(raw_bytes) orelse return;
        allocation.pinned = false;
    }

    pub fn collect(self: *State) AllocError!void {
        errdefer resetAllMarked(self);
        try mark(self);
        try sweep(self);
    }
};
