#include "gc.hpp"
#include <cassert>

int main() {
    garbage_collector_state gc{};

    int* a = (int*)gc.push(sizeof(int));
    int* b = (int*)gc.push(sizeof(int));

    gc.collect();

    assert(a);
    assert(b);

    gc.collect();

    assert(gc.get_allocation_count() == 2);

    return 0;
}
