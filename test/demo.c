#include "CSTL/allocator.h"
#include "CSTL/common.h"
#include "gc.h"
#include <stdio.h>

void test_demo(void);

int main(void) {
    test_demo();

    return 0;
}

static void make_garbage(garbage_collector* gc) {
    void* junk = gc_alloc(gc, sizeof(i32), 1, alignof(i32));
    (void)junk; // dropped when this function returns; nothing keeps it reachable after that
}

void test_demo(void) {
    auto gc = gc_create(std_allocator(), 1); // tiny limit: the next alloc will trigger

    make_garbage(&gc); // allocates 1 int, then loses the only pointer to it

    printf("before: %ld\n", gc.allocations.count); // 1 — junk still tracked, not yet swept

    i32* const keep = (i32*)gc_alloc(&gc, sizeof(i32), 1, alignof(i32));

    // ^ live_bytes(4) >= sweep_limit(1) at entry → this call triggers gc_collect

    //   BEFORE allocating. mark finds nothing pointing at junk's object → it gets freed.

    //   `keep` itself survives, since it's not yet in the table when the check runs.

    *keep = 42;

    printf("after: %ld\n", gc.allocations.count); // 1 — junk gone, keep remains

    gc_destroy(&gc);
}
