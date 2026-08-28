#pragma once
#include "CSTL/allocator.h"
#include "CSTL/common.h"
#include "CSTL/hashmap.h"

#define GLOBAL_SECTION_COUNT 2

typedef enum gc_allocation_flag : u8 {
    gc_allocation_unmarked,
    gc_allocation_marked,
    gc_allocation_pinned,
} gc_allocation_flag;

typedef void* base_ptr;

typedef struct gc_allocation {
    void* base;
    i64 size;
    i64 count;
    i64 align;
    gc_allocation_flag mark;
} gc_allocation;

HASHMAP_DEFINE(base_ptr, gc_allocation)

typedef struct global_section {
    const char* name;
    void* start;
    void* end;
} global_section;

typedef struct garbage_collector {
    hashmap_base_ptr_gc_allocation allocations;
    global_section global_sections[GLOBAL_SECTION_COUNT];
    void* stack_bottom;
    allocator inner_allocator;
    u64 sweep_limit;
    u64 live_bytes;
} garbage_collector;

garbage_collector gc_create(allocator inner_allocator, u64 sweep_limit);
void gc_destroy(garbage_collector* gc);
u8* gc_alloc(garbage_collector* gc, i64 size, i64 count, i64 align);
void gc_pin(garbage_collector* gc, void* base);
void gc_unpin(garbage_collector* gc, void* base);
void gc_collect(garbage_collector* gc);
