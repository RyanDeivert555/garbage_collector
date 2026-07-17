cmake_minimum_required(VERSION 3.28)
project(
    garbage_collector 
    VERSION 0.0.1
    LANGUAGES C
)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# or library
add_executable(${PROJECT_NAME})
set_target_properties(${PROJECT_NAME} PROPERTIES
    C_STANDARD 23
    C_STANDARD_REQUIRED YES
    C_EXTENSIONS NO
)

target_sources(${PROJECT_NAME}
    PRIVATE
    src/main.c
)

target_include_directories(${PROJECT_NAME} PUBLIC include/)
target_compile_options(${PROJECT_NAME} PRIVATE 
    -Wall -Wextra -Wpedantic -Werror
    $<$<CONFIG:Debug>:-fsanitize=address,undefined>
)
target_link_options(${PROJECT_NAME} PRIVATE
    $<$<CONFIG:Debug>:-fsanitize=address,undefined>
)
