#ifndef PASTEHUB_IMAGE_H
#define PASTEHUB_IMAGE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(PH_IMAGE_SHARED)
#if defined(PH_IMAGE_BUILD)
#define PH_IMAGE_API __declspec(dllexport)
#else
#define PH_IMAGE_API __declspec(dllimport)
#endif
#elif defined(__GNUC__)
#define PH_IMAGE_API __attribute__((visibility("default")))
#else
#define PH_IMAGE_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum PHImageFormat {
    PH_IMAGE_PNG = 1,
    PH_IMAGE_JPEG = 2,
    PH_IMAGE_WEBP = 3
} PHImageFormat;

typedef enum PHImageStatus {
    PH_IMAGE_OK = 0,
    PH_IMAGE_INVALID_ARGUMENT = 1,
    PH_IMAGE_DECODE_FAILED = 2,
    PH_IMAGE_ENCODE_FAILED = 3,
    PH_IMAGE_OUT_OF_MEMORY = 4,
    PH_IMAGE_PLATFORM_ERROR = 5
} PHImageStatus;

typedef struct PHImageOptions {
    uint32_t struct_size;
    PHImageFormat format;
    uint32_t width;
    uint32_t height;
    double scale_percent;
    int32_t quality;
    uint32_t webp_lossless;
} PHImageOptions;

// 输出内存由库分配，调用方使用 ph_image_buffer_free 释放；不跨接口传递 C++ 对象。
typedef struct PHImageBuffer {
    uint8_t* data;
    size_t size;
    uint32_t width;
    uint32_t height;
    PHImageFormat format;
} PHImageBuffer;

// 默认 JPG、原尺寸、质量 75；宽高为零时使用 scale_percent，只指定一边时保持比例。
PH_IMAGE_API void ph_image_options_init(PHImageOptions* options);
PH_IMAGE_API const char* ph_image_version(void);
PH_IMAGE_API const char* ph_image_third_party_notices(void);

// 输入编码数据，由平台解码后交给共用核心缩放和编码；支持格式取决于平台解码器。
PH_IMAGE_API PHImageStatus ph_image_convert(const uint8_t* data, size_t size,
    const PHImageOptions* options, PHImageBuffer* output, char* error, size_t error_capacity);

// 输入为非预乘 Alpha 的 8 位 sRGB RGBA；stride 允许大于 width * 4。
PH_IMAGE_API PHImageStatus ph_image_encode_rgba(const uint8_t* rgba, size_t size,
    uint32_t width, uint32_t height, size_t stride, const PHImageOptions* options,
    PHImageBuffer* output, char* error, size_t error_capacity);

PH_IMAGE_API void ph_image_buffer_free(PHImageBuffer* buffer);

#ifdef __cplusplus
}
#endif
#endif
