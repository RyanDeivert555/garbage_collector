const std = @import("std");
const win32 = @import("win32");
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
    const ImageNtHeader = win32.system.diagnostics.debug.IMAGE_NT_HEADERS64;
    const ImageDosHeader = win32.system.system_services.IMAGE_DOS_HEADER;
    const ImageSectionHeader = win32.system.diagnostics.debug.IMAGE_SECTION_HEADER;
    const ModuleEntry = win32.system.diagnostics.tool_help.MODULEENTRY32;

    fn ntHeader(base: [*]const u8) *const ImageNtHeader {
        const header: *const ImageDosHeader = @ptrCast(@alignCast(base));
        const offset: usize = @intCast(header.e_lfanew);

        return @ptrCast(@alignCast(base + offset));
    }

    fn getSections(header: *const ImageNtHeader) [*]const ImageSectionHeader {
        const bytes: [*]const u8 = @ptrCast(@alignCast(header));
        const offset = @offsetOf(ImageNtHeader, "OptionalHeader") + header.FileHeader.SizeOfOptionalHeader;

        return @ptrCast(@alignCast(bytes + offset));
    }

    pub fn getGlobalSections(allocator: Allocator) AllocError![][2]usize {
        const process = win32.kernel32.GetCurrentProcessId();
        const snapshot = win32.kernel32.CreateToolhelp32Snapshot(
            .{ .SNAPMODULE = 1, .SNAPMODULE32 = 1 },
            process,
        );
        defer _ = win32.kernel32.CloseHandle(snapshot);

        var module: ModuleEntry = undefined;
        module.dwSize = @sizeOf(@TypeOf(module));
        var result: std.ArrayList([2]usize) = .empty;
        var has_next = win32.kernel32.Module32First(snapshot, &module);
        // TODO: error checking?
        while (has_next != 0) : (has_next = win32.kernel32.Module32Next(snapshot, &module)) {
            const base = module.modBaseAddr.?;
            const nt = ntHeader(@ptrCast(base));
            const sections = getSections(nt);

            for (sections[0..nt.FileHeader.NumberOfSections]) |section| {
                if (section.Characteristics.MEM_WRITE == 1) {
                    const start = @intFromPtr(base) + section.VirtualAddress;
                    const end = start + section.Misc.VirtualSize;

                    try result.append(allocator, [2]usize{ start, end });
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }
};
