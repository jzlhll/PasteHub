#include "internal.hpp"
#include "third_party_notices.hpp"

#include <webp/encode.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <utility>

namespace ph {

size_t image_bytes(uint32_t width, uint32_t height) {
    const size_t limit = std::numeric_limits<size_t>::max();
    const size_t rowWidth = width;
    if (width == 0 || height == 0 || rowWidth > limit / 4 || height > limit / (rowWidth * 4)) {
        throw Error(PH_IMAGE_INVALID_ARGUMENT, "Image dimensions overflow the pixel buffer");
    }
    return static_cast<size_t>(width) * height * 4;
}

namespace {

struct AxisSample {
    std::vector<uint32_t> positions;
    std::vector<float> weights;
};

std::vector<AxisSample> axis_samples(uint32_t source, uint32_t destination) {
    const double scale = static_cast<double>(source) / destination;
    const double radius = std::max(1.0, scale);
    std::vector<AxisSample> samples(destination);
    for (uint32_t index = 0; index < destination; ++index) {
        const double center = (index + 0.5) * scale - 0.5;
        auto& sample = samples[index];
        double total = 0;
        for (int64_t position = static_cast<int64_t>(std::ceil(center - radius));
             position <= static_cast<int64_t>(std::floor(center + radius)); ++position) {
            const double weight = std::max(0.0, 1.0 - std::abs(position - center) / radius);
            if (weight == 0) continue;
            const auto bounded = static_cast<uint32_t>(std::max<int64_t>(0, std::min<int64_t>(source - 1, position)));
            sample.positions.push_back(bounded);
            sample.weights.push_back(static_cast<float>(weight));
            total += weight;
        }
        for (auto& weight : sample.weights) weight = static_cast<float>(weight / total);
    }
    return samples;
}

Image resized(Image image, uint32_t width, uint32_t height) {
    if (image.width == width && image.height == height) return image;
    const auto horizontal = axis_samples(image.width, width);
    const auto vertical = axis_samples(image.height, height);
    const size_t intermediateCount = image_bytes(width, image.height);
    if (intermediateCount > std::numeric_limits<size_t>::max() / sizeof(float)) {
        throw Error(PH_IMAGE_INVALID_ARGUMENT, "Resized image buffer is too large");
    }
    std::vector<float> intermediate(intermediateCount);
    // 统一使用预乘 Alpha 的可分离抗混叠三角滤波，四端共用相同的缩放实现。
    for (uint32_t y = 0; y < image.height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const auto& sample = horizontal[x];
            const size_t target = (static_cast<size_t>(y) * width + x) * 4;
            for (size_t index = 0; index < sample.positions.size(); ++index) {
                const size_t source = (static_cast<size_t>(y) * image.width + sample.positions[index]) * 4;
                const float alpha = image.rgba[source + 3] / 255.0f;
                for (unsigned channel = 0; channel < 3; ++channel) {
                    intermediate[target + channel] += image.rgba[source + channel] * alpha * sample.weights[index];
                }
                intermediate[target + 3] += image.rgba[source + 3] * sample.weights[index];
            }
        }
    }
    Image output{width, height, std::vector<uint8_t>(image_bytes(width, height))};
    for (uint32_t y = 0; y < height; ++y) {
        const auto& sample = vertical[y];
        for (uint32_t x = 0; x < width; ++x) {
            float channels[4]{};
            for (size_t index = 0; index < sample.positions.size(); ++index) {
                const size_t source = (static_cast<size_t>(sample.positions[index]) * width + x) * 4;
                for (unsigned channel = 0; channel < 4; ++channel) channels[channel] += intermediate[source + channel] * sample.weights[index];
            }
            const size_t target = (static_cast<size_t>(y) * width + x) * 4;
            for (unsigned channel = 0; channel < 3; ++channel) {
                const float value = channels[3] > 0 ? channels[channel] * 255 / channels[3] : 0;
                output.rgba[target + channel] = static_cast<uint8_t>(std::round(std::max(0.0f, std::min(255.0f, value))));
            }
            output.rgba[target + 3] = static_cast<uint8_t>(std::round(std::max(0.0f, std::min(255.0f, channels[3]))));
        }
    }
    return output;
}

void encode(Image image, const PHImageOptions& options, PHImageBuffer* output) {
    if (options.struct_size != sizeof(PHImageOptions) || options.format < PH_IMAGE_PNG || options.format > PH_IMAGE_WEBP
        || options.quality < 0 || options.quality > 100 || options.webp_lossless > 1
        || !std::isfinite(options.scale_percent) || options.scale_percent <= 0) {
        throw Error(PH_IMAGE_INVALID_ARGUMENT, "Invalid image options");
    }
    if ((options.width || options.height) && options.scale_percent != 100) {
        throw Error(PH_IMAGE_INVALID_ARGUMENT, "Use dimensions or scale_percent, not both");
    }
    if (options.webp_lossless && options.format != PH_IMAGE_WEBP) {
        throw Error(PH_IMAGE_INVALID_ARGUMENT, "webp_lossless applies only to WebP");
    }
    double width = image.width;
    double height = image.height;
    if (options.width && options.height) {
        width = options.width;
        height = options.height;
    } else if (options.width) {
        height *= options.width / width;
        width = options.width;
    } else if (options.height) {
        width *= options.height / height;
        height = options.height;
    } else {
        width *= options.scale_percent / 100;
        height *= options.scale_percent / 100;
    }
    const double limit = options.format == PH_IMAGE_WEBP ? 16383 : 65500;
    if (!std::isfinite(width) || !std::isfinite(height) || std::round(width) > limit || std::round(height) > limit) {
        throw Error(PH_IMAGE_INVALID_ARGUMENT, "Output dimensions exceed the format limit");
    }
    const auto targetWidth = static_cast<uint32_t>(std::max(1.0, std::round(width)));
    const auto targetHeight = static_cast<uint32_t>(std::max(1.0, std::round(height)));
    image = resized(std::move(image), targetWidth, targetHeight);
    std::vector<uint8_t> encoded;
    if (options.format == PH_IMAGE_WEBP) {
        uint8_t* bytes = nullptr;
        const size_t size = options.webp_lossless
            ? WebPEncodeLosslessRGBA(image.rgba.data(), static_cast<int>(image.width), static_cast<int>(image.height), static_cast<int>(image.width * 4), &bytes)
            : WebPEncodeRGBA(image.rgba.data(), static_cast<int>(image.width), static_cast<int>(image.height), static_cast<int>(image.width * 4), static_cast<float>(options.quality), &bytes);
        const std::unique_ptr<uint8_t, decltype(&WebPFree)> allocation(bytes, WebPFree);
        if (!bytes || size == 0) throw Error(PH_IMAGE_ENCODE_FAILED, "WebP encoding failed");
        encoded.assign(bytes, bytes + size);
    } else {
        if (options.format == PH_IMAGE_JPEG) {
            for (size_t offset = 0; offset < image.rgba.size(); offset += 4) {
                const unsigned alpha = image.rgba[offset + 3];
                for (unsigned channel = 0; channel < 3; ++channel) {
                    image.rgba[offset + channel] = static_cast<uint8_t>((image.rgba[offset + channel] * alpha + 255 * (255 - alpha) + 127) / 255);
                }
                image.rgba[offset + 3] = 255;
            }
        }
        encoded = encode_platform(image, options.format, options.quality);
    }
    if (encoded.empty()) throw Error(PH_IMAGE_ENCODE_FAILED, "Image encoder returned no data");
    auto* bytes = static_cast<uint8_t*>(std::malloc(encoded.size()));
    if (!bytes) throw std::bad_alloc();
    std::memcpy(bytes, encoded.data(), encoded.size());
    *output = {bytes, encoded.size(), image.width, image.height, options.format};
}

template <typename Function>
PHImageStatus guarded(PHImageBuffer* output, char* error, size_t capacity, Function function) {
    if (error && capacity) error[0] = '\0';
    const auto report = [&](PHImageStatus status, const char* message) {
        if (error && capacity) {
            const size_t count = std::min(capacity - 1, std::strlen(message));
            std::memcpy(error, message, count);
            error[count] = '\0';
        }
        return status;
    };
    try {
        if (!output || output->data) throw Error(PH_IMAGE_INVALID_ARGUMENT, "Output must be initialized and empty");
        *output = {};
        function();
        return PH_IMAGE_OK;
    } catch (const Error& failure) {
        return report(failure.status, failure.what());
    } catch (const std::bad_alloc&) {
        return report(PH_IMAGE_OUT_OF_MEMORY, "Cannot allocate image buffer");
    } catch (const std::exception& failure) {
        return report(PH_IMAGE_PLATFORM_ERROR, failure.what());
    } catch (...) {
        return report(PH_IMAGE_PLATFORM_ERROR, "Unknown image processing error");
    }
}

}
}

extern "C" {

void ph_image_options_init(PHImageOptions* options) {
    if (options) *options = {sizeof(PHImageOptions), PH_IMAGE_JPEG, 0, 0, 100, 75, 0};
}

const char* ph_image_version(void) { return "1.0.0"; }
const char* ph_image_third_party_notices(void) { return kThirdPartyNotices; }

PHImageStatus ph_image_convert(const uint8_t* data, size_t size, const PHImageOptions* options,
                              PHImageBuffer* output, char* error, size_t capacity) {
    return ph::guarded(output, error, capacity, [&] {
        if (!data || size == 0 || !options) throw ph::Error(PH_IMAGE_INVALID_ARGUMENT, "Input data and options are required");
        ph::require_single_frame(data, size);
        ph::encode(ph::decode_platform(data, size), *options, output);
    });
}

PHImageStatus ph_image_encode_rgba(const uint8_t* rgba, size_t size, uint32_t width, uint32_t height,
                                  size_t stride, const PHImageOptions* options, PHImageBuffer* output,
                                  char* error, size_t capacity) {
    return ph::guarded(output, error, capacity, [&] {
        const size_t count = ph::image_bytes(width, height);
        const size_t row = static_cast<size_t>(width) * 4;
        if (!rgba || !options || stride < row || (height > 1 && stride > (std::numeric_limits<size_t>::max() - row) / (height - 1))
            || size < stride * (height - 1) + row) {
            throw ph::Error(PH_IMAGE_INVALID_ARGUMENT, "Invalid RGBA buffer or stride");
        }
        ph::Image image{width, height, std::vector<uint8_t>(count)};
        for (uint32_t y = 0; y < height; ++y) std::memcpy(image.rgba.data() + row * y, rgba + stride * y, row);
        ph::encode(std::move(image), *options, output);
    });
}

void ph_image_buffer_free(PHImageBuffer* buffer) {
    if (buffer) { std::free(buffer->data); *buffer = {}; }
}

}
