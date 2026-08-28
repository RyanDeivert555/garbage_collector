cmake_minimum_required(VERSION 3.28)
project(
    garbage_collector 
    VERSION 0.0.1
    LANGUAGES C
)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(BUILD_SHARED_LIBS "Build using shared libraries" OFF)

include(FetchContent)
FetchContent_Declare(
    cstl
    GIT_REPOSITORY https://github.com/RyanDeivert555/CSTL.git
    GIT_TAG main
)
FetchContent_MakeAvailable(cstl)

add_library(${PROJECT_NAME})
set_target_properties(${PROJECT_NAME} PROPERTIES
    C_STANDARD 23
    C_STANDARD_REQUIRED YES
    C_EXTENSIONS NO
)

target_sources(${PROJECT_NAME}
    PRIVATE
    src/gc.c
)

target_include_directories(${PROJECT_NAME} PUBLIC include/)
target_link_libraries(${PROJECT_NAME} PRIVATE cstl)
target_compile_options(${PROJECT_NAME} PRIVATE 
    -Wall -Wextra -Wpedantic -Werror
    $<$<CONFIG:Debug>:-fsanitize=address,undefined>
)
target_link_options(${PROJECT_NAME} PRIVATE
    $<$<CONFIG:Debug>:-fsanitize=address,undefined>
)

enable_testing()
add_subdirectory(test)
