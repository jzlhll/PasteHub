#pragma once

#include "WindowsSupport.hpp"

#include <cstdint>
#include <optional>
#include <vector>

enum class ImageFormat { png, jpg, webp };

struct Image {
    UINT width = 0;
    UINT height = 0;
    std::vector<uint8_t> rgba;
};

struct DecodedImage {
    Image pixels;
    std::optional<ImageFormat> format;
};

// 管理 WIC 与 libwebp 的解码、方向修正、色彩转换、缩放及编码流程。
class ImageProcessor {
public:
    ImageProcessor();
    DecodedImage decode(const std::vector<uint8_t>& data);
    Image resize(Image image, UINT width, UINT height);
    std::vector<uint8_t> encode(Image image, ImageFormat format, int quality, bool lossless);

private:
    ComApartment apartment_;
    ComPtr<IWICImagingFactory> factory_;
};
