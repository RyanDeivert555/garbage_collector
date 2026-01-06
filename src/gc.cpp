#include "gc.hpp"
#include <new>

namespace gc {
    state::~state() {
        _stack_length = 0;
        // TODO: mark would be a no-op?
        collect();
    }

    void state::mark() {
        for (size_type i = 0; i < _stack_length; i++) {
            _stack[i]._marked = true;
        }
    }

    void state::sweep() {
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

    void state::raw_push(object&& obj) noexcept {
        _stack[_stack_length] = std::move(obj);
        _head = &_stack[_stack_length];
        _stack_length++;
        _allocation_count++;
    }

    state::pointer state::push(state::size_type size) noexcept {
        if (_allocation_count == _allocation_capacity) {
            collect();
        }

        object obj{size, _head};
        raw_push(std::move(obj));

        return obj._ptr;
    }

    void state::collect() {
        const size_type current_alloc_count = _allocation_count;

        mark();
        sweep();

        _allocation_capacity = _allocation_count == 0 ? 1 : current_alloc_count * 2;
    }

    state::size_type state::get_allocation_count() const noexcept {
        return _allocation_count;
    }
} // namespace gc
