#include "gc.hpp"
#include <new>

garbage_collector_state::~garbage_collector_state() {
    _stack_length = 0;
    // TODO: sweep would be a no-op?
    collect();
}

void garbage_collector_state::mark() {
    for (size_type i = 0; i < _stack_length; i++) {
        _stack[i]._marked = true;
    }
}

void garbage_collector_state::sweep() {
    object*& obj = _head;

    while (obj) {
        if (!obj->_marked) {
            object* unreachable = obj;
            obj = unreachable->_next;
            ::operator delete(unreachable->_ptr);
            _allocation_count--;
        } else {
            obj->_marked = false;
            obj = obj->_next;
        }
    }
}

void garbage_collector_state::raw_push(object&& obj) noexcept {
    _stack[_stack_length] = std::move(obj);
    _head = &_stack[_stack_length];
    _stack_length++;
    _allocation_count++;
}

garbage_collector_state::pointer garbage_collector_state::push(garbage_collector_state::size_type size) noexcept {
    if (_allocation_count == _allocation_capacity) {
        collect();
    }

    object obj{size, _head};
    raw_push(std::move(obj));

    return obj._ptr;
}

void garbage_collector_state::collect() {
    const size_type current_alloc_count = _allocation_count;

    mark();
    sweep();

    _allocation_capacity = _allocation_count == 0 ? 1 : current_alloc_count * 2;
}

garbage_collector_state::size_type garbage_collector_state::get_allocation_count() const noexcept {
    return _allocation_count;
}
