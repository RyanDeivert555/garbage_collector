set(GC_TESTS 
    demo
)

foreach(TEST_NAME IN LISTS GC_TESTS)
    add_executable(test_${TEST_NAME} ${TEST_NAME}.c)
    set_target_properties(test_${TEST_NAME} PROPERTIES
        C_STANDARD 23
        C_STANDARD_REQUIRED YES
        C_EXTENSIONS NO
    )

    target_compile_options(test_${TEST_NAME} PRIVATE 
        -Wall -Wextra -Wpedantic -Werror
        $<$<CONFIG:Debug>:-fsanitize=address,undefined>
    )

    target_link_libraries(test_${TEST_NAME} PRIVATE garbage_collector cstl)
    add_test(NAME test_${TEST_NAME} COMMAND test_${TEST_NAME})
    target_link_options(test_${TEST_NAME} PRIVATE
        $<$<CONFIG:Debug>:-fsanitize=address,undefined>
    )
endforeach()
