#include "internal.hpp"

#include <cstring>
#include <optional>

namespace ph {
namespace {

unsigned tiff_orientation(const uint8_t* bytes, size_t size) {
    if (size >= 6 && std::memcmp(bytes, "Exif\0\0", 6) == 0) { bytes += 6; size -= 6; }
    if (size < 8) return 1;
    const bool little = bytes[0] == 'I' && bytes[1] == 'I';
    if (!little && !(bytes[0] == 'M' && bytes[1] == 'M')) return 1;
    const auto u16 = [&](size_t offset) -> std::optional<uint16_t> {
        if (offset > size - 2) return {};
        return little ? static_cast<uint16_t>(bytes[offset] | bytes[offset + 1] << 8)
                      : static_cast<uint16_t>(bytes[offset] << 8 | bytes[offset + 1]);
    };
    const auto u32 = [&](size_t offset) -> std::optional<uint32_t> {
        if (offset > size - 4) return {};
        uint32_t result = 0;
        for (unsigned index = 0; index < 4; ++index) result |= static_cast<uint32_t>(bytes[offset + index]) << (little ? index * 8 : (3 - index) * 8);
        return result;
    };
    const auto offset = u32(4);
    if (u16(2) != 42 || !offset || *offset > size - 2) return 1;
    const auto count = u16(*offset);
    if (!count || *count > (size - *offset - 2) / 12) return 1;
    for (size_t index = 0; index < *count; ++index) {
        const size_t entry = static_cast<size_t>(*offset) + 2 + index * 12;
        if (u16(entry) == 0x0112 && u16(entry + 2) == 3 && u32(entry + 4) == 1) {
            const auto value = u16(entry + 8);
            if (value && *value >= 1 && *value <= 8) return *value;
        }
    }
    return 1;
}

}

unsigned encoded_orientation(const uint8_t* data, size_t size) {
    if (size >= 2 && data[0] == 0xff && data[1] == 0xd8) {
        size_t offset = 2;
        while (offset + 1 < size && data[offset] == 0xff) {
            while (offset < size && data[offset] == 0xff) ++offset;
            if (offset >= size) break;
            const uint8_t marker = data[offset++];
            if (marker == 0xda || marker == 0xd9) break;
            if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
            if (offset + 2 > size) break;
            const size_t length = static_cast<size_t>(data[offset]) * 256 + data[offset + 1];
            if (length < 2 || length > size - offset) break;
            if (marker == 0xe1 && length >= 8 && std::memcmp(data + offset + 2, "Exif\0\0", 6) == 0) {
                return tiff_orientation(data + offset + 2, length - 2);
            }
            offset += length;
        }
    } else if (size >= 12 && std::memcmp(data, "RIFF", 4) == 0 && std::memcmp(data + 8, "WEBP", 4) == 0) {
        size_t offset = 12;
        while (size - offset >= 8) {
            const size_t length = static_cast<size_t>(data[offset + 4]) | static_cast<size_t>(data[offset + 5]) << 8
                | static_cast<size_t>(data[offset + 6]) << 16 | static_cast<size_t>(data[offset + 7]) << 24;
            if (length > size - offset - 8) break;
            if (std::memcmp(data + offset, "EXIF", 4) == 0) return tiff_orientation(data + offset + 8, length);
            const size_t advance = 8 + length + (length & 1);
            if (advance > size - offset) break;
            offset += advance;
        }
    } else if (size >= 8 && std::memcmp(data, "\x89PNG\r\n\x1a\n", 8) == 0) {
        size_t offset = 8;
        while (size - offset >= 12) {
            const size_t length = static_cast<size_t>(data[offset]) << 24 | static_cast<size_t>(data[offset + 1]) << 16
                | static_cast<size_t>(data[offset + 2]) << 8 | data[offset + 3];
            if (length > size - offset - 12) break;
            if (std::memcmp(data + offset + 4, "eXIf", 4) == 0) return tiff_orientation(data + offset + 8, length);
            offset += 12 + length;
        }
    } else if (size >= 8) {
        return tiff_orientation(data, size);
    }
    return 1;
}

void require_single_frame(const uint8_t* data, size_t size) {
    const auto animated = [] { throw Error(PH_IMAGE_DECODE_FAILED, "Only single-frame images are supported"); };
    if (size >= 12 && std::memcmp(data, "RIFF", 4) == 0 && std::memcmp(data + 8, "WEBP", 4) == 0) {
        size_t offset = 12;
        while (size - offset >= 8) {
            const size_t length = static_cast<size_t>(data[offset + 4]) | static_cast<size_t>(data[offset + 5]) << 8
                | static_cast<size_t>(data[offset + 6]) << 16 | static_cast<size_t>(data[offset + 7]) << 24;
            if (length > size - offset - 8) break;
            if (std::memcmp(data + offset, "ANIM", 4) == 0
                || (std::memcmp(data + offset, "VP8X", 4) == 0 && length >= 1 && (data[offset + 8] & 2))) animated();
            const size_t advance = 8 + length + (length & 1);
            if (advance > size - offset) break;
            offset += advance;
        }
    } else if (size >= 8 && std::memcmp(data, "\x89PNG\r\n\x1a\n", 8) == 0) {
        size_t offset = 8;
        while (size - offset >= 12) {
            const size_t length = static_cast<size_t>(data[offset]) << 24 | static_cast<size_t>(data[offset + 1]) << 16
                | static_cast<size_t>(data[offset + 2]) << 8 | data[offset + 3];
            if (length > size - offset - 12) break;
            if (std::memcmp(data + offset + 4, "acTL", 4) == 0 && length >= 4) {
                const uint32_t frames = static_cast<uint32_t>(data[offset + 8]) << 24 | static_cast<uint32_t>(data[offset + 9]) << 16
                    | static_cast<uint32_t>(data[offset + 10]) << 8 | data[offset + 11];
                if (frames > 1) animated();
            }
            offset += 12 + length;
        }
    } else if (size >= 13 && (std::memcmp(data, "GIF87a", 6) == 0 || std::memcmp(data, "GIF89a", 6) == 0)) {
        size_t offset = 13;
        if (data[10] & 0x80) offset += 3u << ((data[10] & 7) + 1);
        if (offset > size) throw Error(PH_IMAGE_DECODE_FAILED, "Invalid GIF color table");
        unsigned frames = 0;
        const auto skipBlocks = [&] {
            while (offset < size) {
                const size_t count = data[offset++];
                if (count == 0) return;
                if (count > size - offset) throw Error(PH_IMAGE_DECODE_FAILED, "Invalid GIF data block");
                offset += count;
            }
        };
        while (offset < size) {
            const uint8_t block = data[offset++];
            if (block == 0x3b) break;
            if (block == 0x21 && offset < size) {
                ++offset;
                skipBlocks();
            } else if (block == 0x2c) {
                if (++frames > 1) animated();
                if (size - offset < 9) throw Error(PH_IMAGE_DECODE_FAILED, "Invalid GIF frame");
                const uint8_t flags = data[offset + 8];
                offset += 9;
                if (flags & 0x80) offset += 3u << ((flags & 7) + 1);
                if (offset >= size) throw Error(PH_IMAGE_DECODE_FAILED, "Invalid GIF pixel data");
                ++offset;
                skipBlocks();
            } else {
                throw Error(PH_IMAGE_DECODE_FAILED, "Invalid GIF block");
            }
        }
    }
}

Image apply_orientation(Image image, unsigned orientation) {
    if (orientation < 2 || orientation > 8) return image;
    Image output{orientation >= 5 ? image.height : image.width, orientation >= 5 ? image.width : image.height, {}};
    output.rgba.resize(image_bytes(output.width, output.height));
    for (uint32_t y = 0; y < image.height; ++y) {
        for (uint32_t x = 0; x < image.width; ++x) {
            uint32_t dx = x, dy = y;
            switch (orientation) {
            case 2: dx = image.width - 1 - x; break;
            case 3: dx = image.width - 1 - x; dy = image.height - 1 - y; break;
            case 4: dy = image.height - 1 - y; break;
            case 5: dx = y; dy = x; break;
            case 6: dx = image.height - 1 - y; dy = x; break;
            case 7: dx = image.height - 1 - y; dy = image.width - 1 - x; break;
            case 8: dx = y; dy = image.width - 1 - x; break;
            }
            std::memcpy(output.rgba.data() + (static_cast<size_t>(dy) * output.width + dx) * 4,
                        image.rgba.data() + (static_cast<size_t>(y) * image.width + x) * 4, 4);
        }
    }
    return output;
}

}
