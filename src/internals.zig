const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;

pub const linux = struct {
    fn onObjectCallback(info: *std.posix.dl_phdr_info, _: usize, ranges: *std.array_list.Managed([2]usize)) AllocError!void {
        for (info.phdr[0..info.phnum]) |phdr| {
            // Find writable segments
            if (phdr.type == .LOAD and phdr.flags.W) {
                const start = info.addr + phdr.vaddr;
                const end = start + phdr.memsz;

                try ranges.append([2]usize{ start, end });
            }
        }
    }

    pub fn getGlobalSections(allocator: Allocator) AllocError![][2]usize {
        var ranges: std.array_list.Managed([2]usize) = .init(allocator);
        try std.posix.dl_iterate_phdr(&ranges, AllocError, onObjectCallback);

        return ranges.toOwnedSlice();
    }
};

pub const windows = struct {
    // use EnumProcessModules

    pub fn getGlobalSections(allocator: Allocator) AllocError![][2]usize {
        _ = allocator;

        return undefined;
    }
};
