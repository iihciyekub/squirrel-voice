cmake_minimum_required(VERSION 3.20)
project(squirrel_voice LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version")

set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp" CACHE PATH "Pinned llama.cpp source directory")
if(NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "llama.cpp not found. Run ./scripts/bootstrap.sh first.")
endif()

# Keep the runtime small: no llama CLI/server/examples. We only need libllama,
# ggml/Metal and mtmd for the R2T2 audio projector.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD ON CACHE BOOL "" FORCE)
set(GGML_METAL ON CACHE BOOL "" FORCE)
set(GGML_ACCELERATE ON CACHE BOOL "" FORCE)

add_subdirectory("${LLAMA_CPP_DIR}" llama_cpp EXCLUDE_FROM_ALL)

add_executable(squirrel-voice
    src/main.cpp
    src/r2t2_runtime.cpp
    src/audio_queue_mic.cpp
    src/wav_reader.cpp
)

target_include_directories(squirrel-voice PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${LLAMA_CPP_DIR}/include"
    "${LLAMA_CPP_DIR}/ggml/include"
    "${LLAMA_CPP_DIR}/tools/mtmd"
)

target_link_libraries(squirrel-voice PRIVATE
    mtmd
    llama
    "-framework AudioToolbox"
    "-framework CoreAudio"
    "-framework CoreFoundation"
)

target_compile_options(squirrel-voice PRIVATE -Wall -Wextra -Wpedantic)
