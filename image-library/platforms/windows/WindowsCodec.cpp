#include "internal.hpp"
#include "wic/ImageProcessor.hpp"

namespace ph {

Image decode_platform(const uint8_t* data, size_t size) {
    ImageProcessor processor;
    auto decoded = processor.decode(std::vector<uint8_t>(data, data + size));
    return {decoded.pixels.width, decoded.pixels.height, std::move(decoded.pixels.rgba)};
}

std::vector<uint8_t> encode_platform(const Image& image, PHImageFormat format, int quality) {
    ImageProcessor processor;
    ::Image native{image.width, image.height, image.rgba};
    return processor.encode(std::move(native), format == PH_IMAGE_PNG ? ImageFormat::png : ImageFormat::jpg, quality, false);
}

}
