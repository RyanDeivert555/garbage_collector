const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const VTable = std.mem.Allocator.VTable;
const AllocError = std.mem.Allocator.Error;

pub const Flag = enum {
    unmarked,
    marked,
    pinned,
};

pub const Allocation = struct {
    memory: []u8,
    alignment: Alignment,
    flag: Flag,
};

pub const GlobalSection = struct {
    name: []const u8,
    memory: []const u8,
};

const AllocationMap = std.AutoHashMapUnmanaged([*]const u8, Allocation);

fn getStackBottom() *anyopaque {
    return @ptrFromInt(0x1);
}

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
    const start: usize = @intFromPtr(memory.ptr);
    const end: usize = @intFromPtr(memory.ptr + memory.len);

    for (start..end) |p| {
        markAddress(gc, @ptrFromInt(p));
    }
}

fn markPinned(gc: *State) void {
    var it = gc.allocations.valueIterator();

    while (it.next()) |allocation| {
        if (allocation.flag == .pinned) {
            markAddress(gc, allocation.memory.ptr);
        }
    }
}

fn markStack(gc: *State) void {
    _ = gc;
    // TODO: get access to stack bottom
}

fn onObjectCallback(info: *std.posix.dl_phdr_info, size: usize, ranges: *std.array_list.Managed([2]usize)) AllocError!void {
    _ = size;

    for (info.phdr[0..info.phnum]) |phdr| {
        if (phdr.type == .LOAD and phdr.flags.W) {
            const start = info.phdr + phdr.vaddr;
            const end = start + phdr.memsz;

            try ranges.append([2]usize{
                @intFromPtr(start),
                @intFromPtr(end),
            });
        }
    }
}

fn markGlobals(gc: *State) void {
    var ranges: std.array_list.Managed([2]usize) = .init(gc.child_allocator);
    defer ranges.deinit();

    _ = std.posix.dl_iterate_phdr(&ranges, AllocError, onObjectCallback) catch unreachable;

    for (ranges.items) |range| {
        const start, const end = range;
        const len = end - start;
        const memory_start: [*]u8 = @ptrFromInt(start);
        const memory = memory_start[0..len];

        markAddressRange(gc, memory);
    }
}

fn mark(gc: *State) void {
    markPinned(gc);
    markStack(gc);
    markGlobals(gc);
}

fn sweep(gc: *State) void {
    // TODO: refactor
    const potential_frees = gc.child_allocator.alloc([*]const u8, gc.allocations.count()) catch unreachable;
    defer gc.child_allocator.free(potential_frees);
    var potential_free_count: u64 = 0;

    var it = gc.allocations.valueIterator();
    while (it.next()) |allocation| {
        if (allocation.flag == .unmarked) {
            potential_frees[potential_free_count] = allocation.memory.ptr;
            potential_free_count += 1;
        } else if (allocation.flag == .marked) {
            allocation.flag = .unmarked;
        }
    }

    for (potential_frees) |memory| {
        const res = gc.allocations.fetchRemove(memory).?;
        gc.live_bytes -= res.value.memory.len;
        gc.child_allocator.rawFree(res.value.memory, res.value.alignment, @returnAddress());
    }

    computeSweepLimit(gc);
}

fn computeSweepLimit(gc: *State) void {
    const growth_factor = 2;
    const floor_bytes = 1 << 20;
    const target = gc.live_bytes * growth_factor;
    gc.sweep_limit = @max(target, floor_bytes);
}

pub const State = struct {
    allocations: AllocationMap,
    global_sections: [global_section_count]GlobalSection,
    stack_bottom: *const anyopaque,
    child_allocator: Allocator,
    sweep_limit: u64,
    live_bytes: u64,

    const global_section_count = 2;

    const vtable: VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    pub fn init(child_allocator: Allocator, sweep_limit: u64) State {
        return .{
            .allocations = .empty,
            .global_sections = [global_section_count]GlobalSection{
                undefined,
                undefined,
            },
            .stack_bottom = getStackBottom(),
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

    fn rawAlloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *State = @ptrCast(@alignCast(ptr));

        if (self.live_bytes > self.sweep_limit) {
            self.collect();
        }

        const base = self.child_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        const memory = base[0..len];
        self.allocations.put(self.child_allocator, base, .{
            .memory = memory,
            .alignment = alignment,
            .flag = .unmarked,
        }) catch {
            self.child_allocator.rawFree(memory, alignment, ret_addr);
            return null;
        };

        self.live_bytes += len;

        return base;
    }

    fn rawResize(self: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = self;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;

        return false;
    }

    fn rawRemap(self: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = self;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;

        return null;
    }

    fn rawFree(self: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = self;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
    }

    pub fn allocator(self: *State) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn pin(self: *State, base: anytype) void {
        const raw_bytes = std.mem.asBytes(base);

        const allocation = self.allocations.getPtr(raw_bytes) orelse return;
        allocation.flag = .pinned;
    }

    pub fn unpin(self: *State, base: anytype) void {
        const raw_bytes = std.mem.asBytes(base);

        const allocation = self.allocations.getPtr(raw_bytes) orelse return;
        allocation.flag = .marked;
    }

    pub fn collect(self: *State) void {
        mark(self);
        sweep(self);
    }
};
