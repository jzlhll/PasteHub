#pragma once

#include "pastehub_image.h"

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace ph {

struct Image {
    uint32_t width;
    uint32_t height;
    std::vector<uint8_t> rgba;
};

// 将平台错误转换成稳定的 C 状态码，异常不跨越公共接口边界。
class Error : public std::runtime_error {
public:
    Error(PHImageStatus status, const std::string& message) : std::runtime_error(message), status(status) {}
    PHImageStatus status;
};

size_t image_bytes(uint32_t width, uint32_t height);
Image decode_platform(const uint8_t* data, size_t size);
std::vector<uint8_t> encode_platform(const Image& image, PHImageFormat format, int quality);
Image apply_orientation(Image image, unsigned orientation);
unsigned encoded_orientation(const uint8_t* data, size_t size);
void require_single_frame(const uint8_t* data, size_t size);

}
