cmake_minimum_required(VERSION 3.28)
project(
    garbage_collector 
    VERSION 0.0.1
    DESCRIPTION "Garbage Collector"
    LANGUAGES CXX
)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_executable(${PROJECT_NAME})

target_sources(${PROJECT_NAME}
    PRIVATE
    src/main.cpp
    src/gc.cpp
)

target_include_directories(${PROJECT_NAME} PUBLIC include/)
target_compile_options(${PROJECT_NAME} PRIVATE 
    -Wall -Wextra -Wpedantic -Werror -std=c++23
    $<$<CONFIG:Debug>:-fsanitize=address,undefined>
)
target_link_options(${PROJECT_NAME} PRIVATE
    $<$<CONFIG:Debug>:-fsanitize=address,undefined>
)
