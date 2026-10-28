# The Windows engine's signal processing and its tests.
#
# The DSP library has no Windows dependency, so it builds with Apple clang on the
# Mac and with MSVC on Windows; both run the same tests against the same reference
# vectors (see README.md).

cmake_minimum_required(VERSION 3.24)
project(TapdeckWindows LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

set(TAPDECK_SANITIZE "" CACHE STRING "Build with a sanitizer: address or thread (clang only)")

# Floating point is kept IEEE on both compilers so results can be compared with
# the Swift code: no fused multiply-add contraction (Apple clang fuses by
# default on arm64) and no fast-math.
if(MSVC)
  set(TAPDECK_WARNINGS /W4 /permissive- /utf-8)
  set(TAPDECK_FLOATING_POINT /fp:precise)
else()
  set(TAPDECK_WARNINGS -Wall -Wextra -Wpedantic)
  set(TAPDECK_FLOATING_POINT -ffp-contract=off -fno-fast-math)
endif()

if(TAPDECK_SANITIZE)
  if(MSVC)
    message(FATAL_ERROR "TAPDECK_SANITIZE is for clang builds")
  endif()
  add_compile_options(-fsanitize=${TAPDECK_SANITIZE} -fno-omit-frame-pointer -g)
  add_link_options(-fsanitize=${TAPDECK_SANITIZE})
endif()

add_library(tapdeck_dsp STATIC
  engine/src/AudioRingBuffer.cpp
  engine/src/GainStage.cpp
  engine/src/RoutingGraph.cpp)
target_include_directories(tapdeck_dsp PUBLIC engine/include)

# The test seams (AudioRingBuffer::testing). On while this build holds only the
# tests; the app's build turns it off.
option(TAPDECK_TESTING "Compile the test seams into the engine" ON)
if(TAPDECK_TESTING)
  target_compile_definitions(tapdeck_dsp PUBLIC TAPDECK_TESTING)
endif()
target_compile_options(tapdeck_dsp PUBLIC ${TAPDECK_FLOATING_POINT} PRIVATE ${TAPDECK_WARNINGS})

find_package(Threads REQUIRED)

enable_testing()
set(TAPDECK_VECTORS "${CMAKE_CURRENT_SOURCE_DIR}/vectors")

foreach(test graphtest gaintest limittest ringtest vectortest)
  add_executable(${test} tests/${test}.cpp tests/VectorFile.cpp)
  target_link_libraries(${test} PRIVATE tapdeck_dsp Threads::Threads)
  target_compile_options(${test} PRIVATE ${TAPDECK_WARNINGS})
endforeach()
foreach(test graphtest gaintest limittest ringtest)
  add_test(NAME ${test} COMMAND ${test})
endforeach()
# vectortest reads its files relative to the working directory: a path on the
# command line would pass through the Windows ANSI code page and lose any
# character outside it.
add_test(NAME vectortest COMMAND vectortest . WORKING_DIRECTORY "${TAPDECK_VECTORS}")
