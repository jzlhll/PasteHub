#include "internal.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <algorithm>
#include <limits>
#include <memory>
#include <type_traits>

namespace ph {
namespace {

// 统一释放 CoreFoundation 与 CoreGraphics 的拥有型引用。
template <typename T>
struct CFReleaseObject { void operator()(T value) const { if (value) CFRelease(value); } };
template <typename T>
using CFHandle = std::unique_ptr<typename std::remove_pointer<T>::type, CFReleaseObject<T>>;

CFHandle<CGContextRef> context_for(Image& image) {
    CFHandle<CGColorSpaceRef> color(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    CFHandle<CGContextRef> context(CGBitmapContextCreate(image.rgba.data(), image.width, image.height, 8,
        static_cast<size_t>(image.width) * 4, color.get(), kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast));
    if (!context) throw Error(PH_IMAGE_PLATFORM_ERROR, "Cannot create sRGB bitmap context");
    return context;
}

}

Image decode_platform(const uint8_t* bytes, size_t size) {
    if (size > static_cast<size_t>(std::numeric_limits<CFIndex>::max())) throw Error(PH_IMAGE_INVALID_ARGUMENT, "Input is too large");
    CFHandle<CFDataRef> data(CFDataCreate(kCFAllocatorDefault, bytes, static_cast<CFIndex>(size)));
    if (!data) throw std::bad_alloc();
    CFHandle<CGImageSourceRef> source(CGImageSourceCreateWithData(data.get(), nullptr));
    if (!source || CGImageSourceGetCount(source.get()) != 1) throw Error(PH_IMAGE_DECODE_FAILED, "Input must be a supported single-frame image");
    CFHandle<CGImageRef> decoded(CGImageSourceCreateImageAtIndex(source.get(), 0, nullptr));
    if (!decoded || CGImageGetWidth(decoded.get()) > UINT32_MAX || CGImageGetHeight(decoded.get()) > UINT32_MAX) {
        throw Error(PH_IMAGE_DECODE_FAILED, "Cannot decode image pixels");
    }
    Image image{static_cast<uint32_t>(CGImageGetWidth(decoded.get())), static_cast<uint32_t>(CGImageGetHeight(decoded.get())), {}};
    image.rgba.resize(image_bytes(image.width, image.height));
    {
        auto context = context_for(image);
        CGContextDrawImage(context.get(), CGRectMake(0, 0, image.width, image.height), decoded.get());
    }
    for (size_t offset = 0; offset < image.rgba.size(); offset += 4) {
        const unsigned alpha = image.rgba[offset + 3];
        if (alpha == 255) continue;
        for (unsigned channel = 0; channel < 3; ++channel) {
            image.rgba[offset + channel] = alpha == 0 ? 0 : static_cast<uint8_t>(std::min(255u, (image.rgba[offset + channel] * 255u + alpha / 2) / alpha));
        }
    }
    unsigned orientation = 1;
    CFHandle<CFDictionaryRef> properties(CGImageSourceCopyPropertiesAtIndex(source.get(), 0, nullptr));
    if (properties) {
        const auto value = static_cast<CFNumberRef>(CFDictionaryGetValue(properties.get(), kCGImagePropertyOrientation));
        int number = 1;
        if (value && CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue(value, kCFNumberIntType, &number)
            && number >= 1 && number <= 8) orientation = static_cast<unsigned>(number);
    }
    return apply_orientation(std::move(image), orientation);
}

std::vector<uint8_t> encode_platform(const Image& input, PHImageFormat format, int quality) {
    Image image = input;
    for (size_t offset = 0; offset < image.rgba.size(); offset += 4) {
        const unsigned alpha = image.rgba[offset + 3];
        for (unsigned channel = 0; channel < 3; ++channel) image.rgba[offset + channel] = static_cast<uint8_t>((image.rgba[offset + channel] * alpha + 127) / 255);
    }
    auto context = context_for(image);
    CFHandle<CGImageRef> bitmap(CGBitmapContextCreateImage(context.get()));
    CFHandle<CFMutableDataRef> data(CFDataCreateMutable(kCFAllocatorDefault, 0));
    const CFStringRef type = format == PH_IMAGE_PNG ? CFSTR("public.png") : CFSTR("public.jpeg");
    CFHandle<CGImageDestinationRef> destination(CGImageDestinationCreateWithData(data.get(), type, 1, nullptr));
    if (!bitmap || !destination) throw Error(PH_IMAGE_ENCODE_FAILED, "Cannot create image encoder");
    double factor = quality / 100.0;
    CFHandle<CFNumberRef> number(CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &factor));
    const void* keys[] = {kCGImageDestinationLossyCompressionQuality};
    const void* values[] = {number.get()};
    CFHandle<CFDictionaryRef> properties(CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    CGImageDestinationAddImage(destination.get(), bitmap.get(), format == PH_IMAGE_JPEG ? properties.get() : nullptr);
    if (!CGImageDestinationFinalize(destination.get())) throw Error(PH_IMAGE_ENCODE_FAILED, "Image encoding failed");
    return {CFDataGetBytePtr(data.get()), CFDataGetBytePtr(data.get()) + CFDataGetLength(data.get())};
}

}
