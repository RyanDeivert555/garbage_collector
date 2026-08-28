#define _GNU_SOURCE
#include "gc.h"
#include "CSTL/allocator.h"
#include <pthread.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define GC_NO_SANITIZE_ADDRESS __attribute__((no_sanitize("address")))
#endif
#endif
#ifndef GC_NO_SANITIZE_ADDRESS
#if defined(__SANITIZE_ADDRESS__)
#define GC_NO_SANITIZE_ADDRESS __attribute__((no_sanitize("address")))
#else
#define GC_NO_SANITIZE_ADDRESS
#endif
#endif

// Suppress false positive
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
const char* __asan_default_options(void) {
    return "detect_stack_use_after_return=0";
}
#endif
#elif defined(__SANITIZE_ADDRESS__)
const char* __asan_default_options(void) {
    return "detect_stack_use_after_return=0";
}
#endif

static bool header_eql(const void* a, const void* b) {
    return a == b;
}

static u64 header_hash(const void* p) {
    return (usize)p / 8;
}

HASHMAP_IMPL(base_ptr, gc_allocation, header_eql, header_hash)

// .data start
extern char __data_start;
// .data end
extern char _edata;
// .bss start
extern char __bss_start;
// .bss end
extern char _end;

static void* stack_bottom(void) {
    const pthread_t curr_thread = pthread_self();
    pthread_attr_t attr = {0};
    if (pthread_getattr_np(curr_thread, &attr) != 0) {
        return NULL;
    }

    void* stack_bottom = NULL;
    size_t stack_size = 0;
    if (pthread_attr_getstack(&attr, &stack_bottom, &stack_size) != 0) {
        pthread_attr_destroy(&attr);
        return NULL;
    }

    pthread_attr_destroy(&attr);
    return (uint8_t*)stack_bottom + stack_size;
}

garbage_collector gc_create(allocator inner_allocator, u64 sweep_limit) {
    garbage_collector gc = {0};
    gc.allocations = hashmap_base_ptr_gc_allocation_create(inner_allocator);
    gc.global_sections[0] = (global_section){
        .name = ".data",
        .start = &__data_start,
        .end = &_edata,
    };
    gc.global_sections[1] = (global_section){
        ".bss",
        &__bss_start,
        &_end,
    };
    gc.stack_bottom = stack_bottom();
    gc.inner_allocator = inner_allocator;
    gc.sweep_limit = sweep_limit;

    return gc;
}

void gc_destroy(garbage_collector* gc) {
    auto it = hashmap_base_ptr_gc_allocation_iterator_new(&gc->allocations);
    while (hashmap_base_ptr_gc_allocation_iterator_next(&it)) {
        gc_allocation* const allocation = &it.value;
        cstl_raw_free(gc->inner_allocator, allocation->base, allocation->size, allocation->count, allocation->align);
    }
    hashmap_base_ptr_gc_allocation_free(&gc->allocations);
}

static void mark_address(garbage_collector* gc, void* ptr);
static void mark_address_range(garbage_collector* gc, void* start, void* end);

// TODO add version that takes gc_allocation
static void mark_address(garbage_collector* gc, void* ptr) {
    gc_allocation* const allocation = hashmap_base_ptr_gc_allocation_get(&gc->allocations, ptr);
    if (!allocation) {
        return;
    }
    if (allocation->mark == gc_allocation_marked) {
        return;
    }

    allocation->mark = gc_allocation_marked;
    mark_address_range(gc, allocation->base, (u8*)allocation->base + allocation->size);
}

GC_NO_SANITIZE_ADDRESS static void mark_address_range(garbage_collector* gc, void* start, void* end) {
    for (usize* p = start; p < (usize*)end; p++) {
        void* const addr = (void*)*p;
        mark_address(gc, addr);
    }
}

static void mark_pinned(garbage_collector* gc) {
    auto it = hashmap_base_ptr_gc_allocation_iterator_new(&gc->allocations);
    while (hashmap_base_ptr_gc_allocation_iterator_next(&it)) {
        if (it.value.mark == gc_allocation_pinned) {
            mark_address(gc, it.value.base);
        }
    }
}

static void mark_stack(garbage_collector* gc) {
    jmp_buf env = {0};
    void* stack_top = NULL;
    if (setjmp(env) == 0) {
        stack_top = &env;
    }
    cstl_assert(stack_top);

    // stack grows down
    if (gc->stack_bottom > stack_top) {
        mark_address_range(gc, stack_top, gc->stack_bottom);
    }
    // stack growns down
    else {
        mark_address_range(gc, gc->stack_bottom, stack_top);
    }
}

static void mark_globals(garbage_collector* gc) {
    for (i64 i = 0; i < GLOBAL_SECTION_COUNT; i++) {
        mark_address_range(gc, gc->global_sections[i].start, gc->global_sections[i].end);
    }
}

static void compute_sweep_limit(garbage_collector* gc) {
    static const u64 growth_factor = 2;
    static const u64 floor_bytes = 1 << 20;
    const u64 target = gc->live_bytes * growth_factor;
    gc->sweep_limit = target > floor_bytes ? target : floor_bytes;
}

u8* gc_alloc(garbage_collector* gc, i64 size, i64 count, i64 align) {
    if (gc->live_bytes > gc->sweep_limit) {
        gc_collect(gc);
    }

    void* const base = cstl_raw_alloc(gc->inner_allocator, size, count, align);
    const gc_allocation allocation = {
        .base = base,
        .size = size,
        .count = count,
        .align = align,
        .mark = gc_allocation_unmarked,
    };
    hashmap_base_ptr_gc_allocation_set(&gc->allocations, base, allocation);
    gc->live_bytes += size * count;

    return (u8*)base;
}

void gc_pin(garbage_collector* gc, void* base) {
    gc_allocation* const allocation = hashmap_base_ptr_gc_allocation_get(&gc->allocations, base);
    if (allocation) {
        allocation->mark = gc_allocation_pinned;
    }
}

void gc_unpin(garbage_collector* gc, void* base) {
    gc_allocation* const allocation = hashmap_base_ptr_gc_allocation_get(&gc->allocations, base);
    if (allocation) {
        allocation->mark = gc_allocation_marked;
    }
}

static void gc_mark(garbage_collector* gc) {
    mark_pinned(gc);
    mark_stack(gc);
    mark_globals(gc);
}

static void gc_sweep(garbage_collector* gc) {
    void** const potential_frees = cstl_alloc(void*, gc->inner_allocator, gc->allocations.count);
    i64 potential_frees_count = 0;
    auto it = hashmap_base_ptr_gc_allocation_iterator_new(&gc->allocations);
    while (hashmap_base_ptr_gc_allocation_iterator_next(&it)) {
        gc_allocation* const allocation = &it.value;
        if (allocation->mark == gc_allocation_unmarked) {
            potential_frees[potential_frees_count++] = allocation->base;
        } else if (allocation->mark == gc_allocation_marked) {
            allocation->mark = gc_allocation_unmarked;
        }
    }

    for (i64 i = 0; i < potential_frees_count; i++) {
        void* const base = potential_frees[i];
        gc_allocation allocation = {0};
        if (hashmap_base_ptr_gc_allocation_try_remove(&gc->allocations, base, &allocation)) {
            gc->live_bytes -= allocation.size * allocation.count;
            cstl_raw_free(gc->inner_allocator, base, allocation.size, allocation.count, allocation.align);
        }
    }

    cstl_free(void*, gc->inner_allocator, potential_frees, gc->allocations.count);
    compute_sweep_limit(gc);
}

void gc_collect(garbage_collector* gc) {
    gc_mark(gc);
    gc_sweep(gc);
}
