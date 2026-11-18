cmake_minimum_required(VERSION 3.16)
project(p1bench LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# 保留符号与帧指针，方便外部 perf / heaptrack 采样与回溯
set(CMAKE_CXX_FLAGS_DEBUG   "-O0 -g3 -fno-omit-frame-pointer")
set(CMAKE_CXX_FLAGS_RELEASE "-O2 -g -DNDEBUG -fno-omit-frame-pointer")

set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

# ---- 被测目标 1：CPU 密集型动态库 ----------------------------------------
add_library(cpuwork SHARED libcpuwork/cpu_work.cpp)
target_include_directories(cpuwork PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_compile_options(cpuwork PRIVATE -Wall -Wextra)

# ---- 被测目标 2：内存密集型动态库 ----------------------------------------
add_library(memwork SHARED libmemwork/mem_work.cpp)
target_include_directories(memwork PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_compile_options(memwork PRIVATE -Wall -Wextra)

# ---- 驱动程序 ------------------------------------------------------------
add_executable(bench src/main.cpp)
target_link_libraries(bench PRIVATE cpuwork memwork)
target_compile_definitions(bench PRIVATE BENCH_BUILD_TYPE="${CMAKE_BUILD_TYPE}")
target_compile_options(bench PRIVATE -Wall -Wextra)

# 可执行文件与 .so 的相对布局: <build>/bin/bench, <build>/lib/lib*.so
set_target_properties(bench PROPERTIES
    BUILD_RPATH "\$ORIGIN/../lib"
    INSTALL_RPATH "\$ORIGIN/../lib"
)
