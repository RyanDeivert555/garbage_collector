#pragma once
#include <array>
#include <cstddef>
#include <new>

struct garbage_collector_state {
public:
    using size_type = std::size_t;
    using difference_type = std::ptrdiff_t;

private:
    using pointer = void*;

    struct object {
        pointer _ptr;
        object* _next;
        bool _marked;

        object() = default;
        object(size_type size, object* next) : _ptr(::operator new(size)), _next(next), _marked(false) {}
    };

    static constexpr size_type _stack_size = 1 << 8;

    // TODO: this means there is a max amount of objects allocated, not good
    std::array<object, _stack_size> _stack{};
    size_type _stack_length{};

    size_type _allocation_count{};
    size_type _allocation_capacity{};

    object* _head{};

    void mark();
    void sweep();

public:
    garbage_collector_state() = default;
    ~garbage_collector_state();
    garbage_collector_state(const garbage_collector_state&) = delete;
    garbage_collector_state& operator=(const garbage_collector_state&) = delete;
    // TODO: move constructors?

    void raw_push(object&& obj) noexcept;
    pointer push(size_type size) noexcept;
    void collect();

    size_type get_allocation_count() const noexcept;
};

template <typename T>
struct garbage_collector {
private:
    garbage_collector_state* _state{};

public:
    using value_type = T;
    using pointer = T*;
    using const_pointer = const T*;
    using reference = T&;
    using const_reference = const T&;
    using size_type = garbage_collector_state::size_type;
    using difference_type = garbage_collector_state::difference_type;

    garbage_collector(garbage_collector_state& state) : _state(&state) {}

    pointer allocate(size_type count) {
        return _state->push(count * sizeof(T));
    }

    // TODO: no-op?
    void deallocate(pointer, size_type) {}
};
