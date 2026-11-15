cmake_minimum_required(VERSION 3.24)

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
project(pastehub_image_windows VERSION 0.1.0 LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "Configure for a Windows target, using a native or cross-compiling toolchain.")
endif()

if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE MinSizeRel CACHE STRING "Build configuration" FORCE)
endif()

# 仅查找本地已安装的依赖，不在构建脚本中下载或拉取源码。
find_package(WebP 1.6 CONFIG REQUIRED)
foreach(component webp webpdemux)
    if(NOT TARGET WebP::${component})
        message(FATAL_ERROR "The installed WebP package must provide WebP::${component}.")
    endif()
    get_target_property(component_type WebP::${component} TYPE)
    if(component_type STREQUAL "SHARED_LIBRARY")
        message(FATAL_ERROR "Use a static WebP package to produce a standalone executable.")
    endif()
endforeach()

# 嵌入实际安装版本的授权文本，避免运行时依赖额外的许可证文件。
set(PASTEHUB_WEBP_NOTICE_FILE "" CACHE FILEPATH "Copyright/license file shipped with the installed libwebp package")
if(NOT PASTEHUB_WEBP_NOTICE_FILE)
    find_file(webp_notice
        NAMES copyright
        HINTS
            "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/share/libwebp"
            "${WebP_DIR}/../libwebp"
            "${WebP_DIR}"
    )
    if(webp_notice)
        set(PASTEHUB_WEBP_NOTICE_FILE "${webp_notice}" CACHE FILEPATH "Copyright/license file shipped with the installed libwebp package" FORCE)
    endif()
endif()
if(NOT EXISTS "${PASTEHUB_WEBP_NOTICE_FILE}")
    message(FATAL_ERROR "Set PASTEHUB_WEBP_NOTICE_FILE to the installed libwebp copyright file, including its license and patent grant.")
endif()
file(READ "${PASTEHUB_WEBP_NOTICE_FILE}" PASTEHUB_WEBP_NOTICES)
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
configure_file(cmake/ThirdPartyNotices.hpp.in generated/ThirdPartyNotices.hpp @ONLY)

add_executable(pastehub-image
    src/main.cpp
    src/ImageProcessor.cpp
)
target_compile_features(pastehub-image PRIVATE cxx_std_17)
set_target_properties(pastehub-image PROPERTIES CXX_EXTENSIONS OFF)
target_compile_definitions(pastehub-image PRIVATE
    UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN
    WINVER=0x0A00 _WIN32_WINNT=0x0A00
)
target_include_directories(pastehub-image PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(pastehub-image PRIVATE
    WebP::webpdemux WebP::webp
    windowscodecs ole32 uuid
)

if(MSVC)
    target_compile_options(pastehub-image PRIVATE /W4 /utf-8 /Gy /Gw)
    target_link_options(pastehub-image PRIVATE
        "$<$<NOT:$<CONFIG:Debug>>:/OPT:REF>"
        "$<$<NOT:$<CONFIG:Debug>>:/OPT:ICF>"
        "$<$<NOT:$<CONFIG:Debug>>:/INCREMENTAL:NO>"
    )
elseif(MINGW)
    target_compile_options(pastehub-image PRIVATE -Wall -Wextra -Wpedantic -ffunction-sections -fdata-sections)
    target_link_options(pastehub-image PRIVATE
        -municode -static -static-libgcc -static-libstdc++
        "$<$<NOT:$<CONFIG:Debug>>:-Wl,--gc-sections>"
        "$<$<NOT:$<CONFIG:Debug>>:-s>"
    )
endif()

install(TARGETS pastehub-image RUNTIME DESTINATION .)
