#include "ImageProcessor.hpp"

#include <webp/decode.h>
#include <webp/demux.h>
#include <webp/encode.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <memory>

namespace {

UINT imageByteCount(UINT width, UINT height) {
    const UINT limit = std::numeric_limits<UINT>::max();
    if (width == 0 || height == 0 || width > limit / 4 || height > limit / (width * 4)) {
        throw std::runtime_error("Image exceeds the supported WIC pixel buffer size");
    }
    return width * height * 4;
}

ComPtr<IStream> memoryStream(const std::vector<uint8_t>* input = nullptr) {
    ComPtr<IStream> stream;
    checkHRESULT(CreateStreamOnHGlobal(nullptr, TRUE, stream.put()), "Create memory stream");
    if (input) {
        if (input->size() > std::numeric_limits<ULONG>::max()) throw std::runtime_error("Input stream is too large");
        ULONG written = 0;
        checkHRESULT(stream->Write(input->data(), static_cast<ULONG>(input->size()), &written), "Initialize input stream");
        if (written != input->size()) throw std::runtime_error("Incomplete input stream write");
        LARGE_INTEGER zero{};
        checkHRESULT(stream->Seek(zero, STREAM_SEEK_SET, nullptr), "Rewind input stream");
    }
    return stream;
}

std::vector<uint8_t> streamBytes(IStream* stream) {
    STATSTG statistics{};
    checkHRESULT(stream->Stat(&statistics, STATFLAG_NONAME), "Read encoded stream size");
    if (statistics.cbSize.QuadPart == 0 || statistics.cbSize.QuadPart > std::numeric_limits<ULONG>::max()) {
        throw std::runtime_error("Encoded stream is empty or too large");
    }
    std::vector<uint8_t> output(static_cast<size_t>(statistics.cbSize.QuadPart));
    LARGE_INTEGER zero{};
    checkHRESULT(stream->Seek(zero, STREAM_SEEK_SET, nullptr), "Rewind output stream");
    ULONG read = 0;
    checkHRESULT(stream->Read(output.data(), static_cast<ULONG>(output.size()), &read), "Read encoded stream");
    if (read != output.size()) throw std::runtime_error("Incomplete encoded stream read");
    return output;
}

ComPtr<IWICBitmap> bitmapFromImage(IWICImagingFactory* factory, Image& image) {
    ComPtr<IWICBitmap> bitmap;
    checkHRESULT(factory->CreateBitmapFromMemory(image.width, image.height, GUID_WICPixelFormat32bppRGBA,
                                                  image.width * 4, imageByteCount(image.width, image.height),
                                                  image.rgba.data(), bitmap.put()), "Create RGBA bitmap");
    return bitmap;
}

ComPtr<IWICFormatConverter> convertFormat(IWICImagingFactory* factory, IWICBitmapSource* source,
                                         REFWICPixelFormatGUID format) {
    ComPtr<IWICFormatConverter> converter;
    checkHRESULT(factory->CreateFormatConverter(converter.put()), "Create pixel format converter");
    checkHRESULT(converter->Initialize(source, format, WICBitmapDitherTypeNone, nullptr, 0,
                                        WICBitmapPaletteTypeCustom), "Convert pixel format");
    return converter;
}

Image copyRGBA(IWICImagingFactory* factory, IWICBitmapSource* source, IWICColorContext* sourceColor = nullptr) {
    ComPtr<IWICColorTransform> transform;
    ComPtr<IWICColorContext> destinationColor;
    ComPtr<IWICFormatConverter> converter;
    IWICBitmapSource* converted = nullptr;
    if (sourceColor) {
        WICPixelFormatGUID sourceFormat{};
        checkHRESULT(source->GetPixelFormat(&sourceFormat), "Read source pixel format");
        // 色彩转换器不直接接受索引色及一位灰度，先转成同色彩模型的像素格式。
        if (IsEqualGUID(sourceFormat, GUID_WICPixelFormat1bppIndexed)
            || IsEqualGUID(sourceFormat, GUID_WICPixelFormat2bppIndexed)
            || IsEqualGUID(sourceFormat, GUID_WICPixelFormat4bppIndexed)
            || IsEqualGUID(sourceFormat, GUID_WICPixelFormat8bppIndexed)) {
            converter = convertFormat(factory, source, GUID_WICPixelFormat32bppRGBA);
            source = converter.get();
        } else if (IsEqualGUID(sourceFormat, GUID_WICPixelFormatBlackWhite)) {
            converter = convertFormat(factory, source, GUID_WICPixelFormat8bppGray);
            source = converter.get();
        }
        checkHRESULT(factory->CreateColorContext(destinationColor.put()), "Create sRGB color context");
        checkHRESULT(destinationColor->InitializeFromExifColorSpace(1), "Initialize sRGB color context");
        checkHRESULT(factory->CreateColorTransformer(transform.put()), "Create color transform");
        checkHRESULT(transform->Initialize(source, sourceColor, destinationColor.get(), GUID_WICPixelFormat32bppRGBA),
                     "Convert input color profile to sRGB");
        converted = transform.get();
    } else {
        // 无色彩配置时按 sRGB 解释；WIC 负责高位深、索引色及 Alpha 的格式转换。
        converter = convertFormat(factory, source, GUID_WICPixelFormat32bppRGBA);
        converted = converter.get();
    }
    Image image;
    checkHRESULT(converted->GetSize(&image.width, &image.height), "Read bitmap dimensions");
    image.rgba.resize(imageByteCount(image.width, image.height));
    checkHRESULT(converted->CopyPixels(nullptr, image.width * 4, static_cast<UINT>(image.rgba.size()),
                                       image.rgba.data()), "Copy RGBA pixels");
    return image;
}

ComPtr<IWICColorContext> frameColorContext(IWICImagingFactory* factory, IWICBitmapFrameDecode* frame) {
    UINT count = 0;
    const HRESULT queried = frame->GetColorContexts(0, nullptr, &count);
    if (queried == WINCODEC_ERR_UNSUPPORTEDOPERATION || queried == E_NOTIMPL) return {};
    checkHRESULT(queried, "Query input color contexts");
    if (count == 0) return {};
    std::vector<ComPtr<IWICColorContext>> contexts(count);
    std::vector<IWICColorContext*> pointers(count);
    for (UINT index = 0; index < count; ++index) {
        checkHRESULT(factory->CreateColorContext(contexts[index].put()), "Create input color context");
        pointers[index] = contexts[index].get();
    }
    UINT actual = 0;
    checkHRESULT(frame->GetColorContexts(count, pointers.data(), &actual), "Read input color contexts");
    for (UINT index = 0; index < actual && index < count; ++index) {
        WICColorContextType type = WICColorContextUninitialized;
        checkHRESULT(contexts[index]->GetType(&type), "Read input color context type");
        if (type != WICColorContextUninitialized) return std::move(contexts[index]);
    }
    return {};
}

unsigned frameOrientation(IWICBitmapFrameDecode* frame) {
    ComPtr<IWICMetadataQueryReader> reader;
    if (FAILED(frame->GetMetadataQueryReader(reader.put()))) return 1;
    for (const wchar_t* query : {L"/app1/ifd/{ushort=274}", L"/ifd/{ushort=274}"}) {
        PROPVARIANT value{};
        const HRESULT result = reader->GetMetadataByName(query, &value);
        unsigned orientation = 0;
        if (SUCCEEDED(result)) {
            if (value.vt == VT_UI2) orientation = value.uiVal;
            if (value.vt == VT_UI4) orientation = value.ulVal;
        }
        PropVariantClear(&value);
        if (orientation >= 1 && orientation <= 8) return orientation;
    }
    return 1;
}

unsigned exifOrientation(const std::vector<uint8_t>& metadata) {
    size_t start = 0;
    if (metadata.size() >= 6 && std::memcmp(metadata.data(), "Exif\0\0", 6) == 0) start = 6;
    if (metadata.size() - start < 8) return 1;
    const auto* data = metadata.data() + start;
    const size_t size = metadata.size() - start;
    const bool little = data[0] == 'I' && data[1] == 'I';
    if (!little && !(data[0] == 'M' && data[1] == 'M')) return 1;
    const auto u16 = [&](size_t offset) -> std::optional<uint16_t> {
        if (offset > size - 2) return std::nullopt;
        if (little) return static_cast<uint16_t>(data[offset] | (data[offset + 1] << 8));
        return static_cast<uint16_t>((data[offset] << 8) | data[offset + 1]);
    };
    const auto u32 = [&](size_t offset) -> std::optional<uint32_t> {
        if (offset > size - 4) return std::nullopt;
        uint32_t value = 0;
        for (unsigned index = 0; index < 4; ++index) {
            const unsigned shift = little ? index * 8 : (3 - index) * 8;
            value |= static_cast<uint32_t>(data[offset + index]) << shift;
        }
        return value;
    };
    if (u16(2) != 42) return 1;
    const auto offset = u32(4);
    if (!offset || *offset > size - 2) return 1;
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

Image applyOrientation(Image image, unsigned orientation) {
    if (orientation == 1) return image;
    const bool transpose = orientation >= 5;
    Image output{transpose ? image.height : image.width, transpose ? image.width : image.height, {}};
    output.rgba.resize(imageByteCount(output.width, output.height));
    for (UINT y = 0; y < image.height; ++y) {
        for (UINT x = 0; x < image.width; ++x) {
            UINT targetX = x;
            UINT targetY = y;
            switch (orientation) {
            case 2: targetX = image.width - 1 - x; break;
            case 3: targetX = image.width - 1 - x; targetY = image.height - 1 - y; break;
            case 4: targetY = image.height - 1 - y; break;
            case 5: targetX = y; targetY = x; break;
            case 6: targetX = image.height - 1 - y; targetY = x; break;
            case 7: targetX = image.height - 1 - y; targetY = image.width - 1 - x; break;
            case 8: targetX = y; targetY = image.width - 1 - x; break;
            default: throw std::runtime_error("Invalid EXIF orientation");
            }
            const size_t source = (static_cast<size_t>(y) * image.width + x) * 4;
            const size_t destination = (static_cast<size_t>(targetY) * output.width + targetX) * 4;
            std::memcpy(output.rgba.data() + destination, image.rgba.data() + source, 4);
        }
    }
    return output;
}

std::vector<uint8_t> webpChunk(const WebPDemuxer* demuxer, const char* name) {
    WebPChunkIterator iterator{};
    if (!WebPDemuxGetChunk(demuxer, name, 1, &iterator)) return {};
    struct IteratorRelease {
        WebPChunkIterator* value;
        ~IteratorRelease() { WebPDemuxReleaseChunkIterator(value); }
    } cleanup{&iterator};
    if (iterator.chunk.size == 0) return {};
    return {iterator.chunk.bytes, iterator.chunk.bytes + iterator.chunk.size};
}

DecodedImage decodeWebP(IWICImagingFactory* factory, const std::vector<uint8_t>& data) {
    WebPBitstreamFeatures features{};
    if (WebPGetFeatures(data.data(), data.size(), &features) != VP8_STATUS_OK) {
        throw std::runtime_error("Invalid WebP image");
    }
    const WebPData webpData{data.data(), data.size()};
    const std::unique_ptr<WebPDemuxer, decltype(&WebPDemuxDelete)> demuxer(WebPDemux(&webpData), WebPDemuxDelete);
    if (!demuxer) throw std::runtime_error("Cannot read WebP container");
    if (features.has_animation || WebPDemuxGetI(demuxer.get(), WEBP_FF_FRAME_COUNT) != 1) {
        throw std::runtime_error("Only single-frame images are supported");
    }
    Image image{static_cast<UINT>(features.width), static_cast<UINT>(features.height), {}};
    image.rgba.resize(imageByteCount(image.width, image.height));
    if (!WebPDecodeRGBAInto(data.data(), data.size(), image.rgba.data(), image.rgba.size(), static_cast<int>(image.width * 4))) {
        throw std::runtime_error("Cannot decode WebP pixels");
    }
    const auto profile = webpChunk(demuxer.get(), "ICCP");
    if (!profile.empty()) {
        if (profile.size() > std::numeric_limits<UINT>::max()) throw std::runtime_error("WebP color profile is too large");
        ComPtr<IWICColorContext> color;
        checkHRESULT(factory->CreateColorContext(color.put()), "Create WebP color context");
        checkHRESULT(color->InitializeFromMemory(profile.data(), static_cast<UINT>(profile.size())), "Read WebP color profile");
        auto bitmap = bitmapFromImage(factory, image);
        image = copyRGBA(factory, bitmap.get(), color.get());
    }
    return {applyOrientation(std::move(image), exifOrientation(webpChunk(demuxer.get(), "EXIF"))), ImageFormat::webp};
}

std::vector<uint8_t> encodeWIC(IWICImagingFactory* factory, Image& image, ImageFormat format, int quality) {
    auto stream = memoryStream();
    ComPtr<IWICBitmapEncoder> encoder;
    checkHRESULT(factory->CreateEncoder(format == ImageFormat::png ? GUID_ContainerFormatPng : GUID_ContainerFormatJpeg,
                                         nullptr, encoder.put()), "Create output encoder");
    checkHRESULT(encoder->Initialize(stream.get(), WICBitmapEncoderNoCache), "Initialize output encoder");
    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> properties;
    checkHRESULT(encoder->CreateNewFrame(frame.put(), properties.put()), "Create output frame");
    if (format == ImageFormat::jpg) {
        if (!properties.get()) throw std::runtime_error("JPEG encoder does not expose quality settings");
        wchar_t name[] = L"ImageQuality";
        PROPBAG2 property{};
        property.pstrName = name;
        VARIANT value{};
        value.vt = VT_R4;
        value.fltVal = static_cast<float>(quality) / 100;
        checkHRESULT(properties->Write(1, &property, &value), "Set JPEG quality");
        // 在编码前铺白底，使 JPG 的透明区域处理与 macOS 版本一致。
        for (size_t offset = 0; offset < image.rgba.size(); offset += 4) {
            const unsigned alpha = image.rgba[offset + 3];
            for (size_t channel = 0; channel < 3; ++channel) {
                image.rgba[offset + channel] = static_cast<uint8_t>(
                    (image.rgba[offset + channel] * alpha + 255 * (255 - alpha) + 127) / 255);
            }
            image.rgba[offset + 3] = 255;
        }
    }
    checkHRESULT(frame->Initialize(properties.get()), "Initialize output frame");
    checkHRESULT(frame->SetSize(image.width, image.height), "Set output dimensions");
    WICPixelFormatGUID pixelFormat = format == ImageFormat::png
        ? GUID_WICPixelFormat32bppBGRA : GUID_WICPixelFormat24bppBGR;
    checkHRESULT(frame->SetPixelFormat(&pixelFormat), "Set encoder pixel format");
    auto bitmap = bitmapFromImage(factory, image);
    auto converted = convertFormat(factory, bitmap.get(), pixelFormat);
    checkHRESULT(frame->WriteSource(converted.get(), nullptr), "Encode output frame");
    checkHRESULT(frame->Commit(), "Commit output frame");
    checkHRESULT(encoder->Commit(), "Commit output image");
    return streamBytes(stream.get());
}

}

ImageProcessor::ImageProcessor() {
    checkHRESULT(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_IWICImagingFactory, reinterpret_cast<void**>(factory_.put())),
                 "Create WIC imaging factory");
}

DecodedImage ImageProcessor::decode(const std::vector<uint8_t>& data) {
    if (data.size() >= 12 && std::memcmp(data.data(), "RIFF", 4) == 0 && std::memcmp(data.data() + 8, "WEBP", 4) == 0) {
        return decodeWebP(factory_.get(), data);
    }
    auto stream = memoryStream(&data);
    ComPtr<IWICBitmapDecoder> decoder;
    checkHRESULT(factory_->CreateDecoderFromStream(stream.get(), nullptr, WICDecodeMetadataCacheOnLoad, decoder.put()),
                 "Decode input image; an installed WIC codec is required for this format");
    UINT frameCount = 0;
    checkHRESULT(decoder->GetFrameCount(&frameCount), "Read input frame count");
    if (frameCount != 1) throw std::runtime_error("Only single-frame images are supported");
    ComPtr<IWICBitmapFrameDecode> frame;
    checkHRESULT(decoder->GetFrame(0, frame.put()), "Read input frame");
    auto color = frameColorContext(factory_.get(), frame.get());
    auto image = copyRGBA(factory_.get(), frame.get(), color.get());
    image = applyOrientation(std::move(image), frameOrientation(frame.get()));
    GUID container{};
    checkHRESULT(decoder->GetContainerFormat(&container), "Read input format");
    std::optional<ImageFormat> format;
    if (IsEqualGUID(container, GUID_ContainerFormatPng)) format = ImageFormat::png;
    if (IsEqualGUID(container, GUID_ContainerFormatJpeg)) format = ImageFormat::jpg;
    return {std::move(image), format};
}

Image ImageProcessor::resize(Image image, UINT width, UINT height) {
    imageByteCount(width, height);
    if (width == image.width && height == image.height) return image;
    auto bitmap = bitmapFromImage(factory_.get(), image);
    // 先使用预乘 Alpha 缩放，再转回 RGBA，避免透明边缘出现黑边。
    auto premultiplied = convertFormat(factory_.get(), bitmap.get(), GUID_WICPixelFormat32bppPBGRA);
    ComPtr<IWICBitmapScaler> scaler;
    checkHRESULT(factory_->CreateBitmapScaler(scaler.put()), "Create image scaler");
    checkHRESULT(scaler->Initialize(premultiplied.get(), width, height, WICBitmapInterpolationModeHighQualityCubic),
                 "Resize image");
    return copyRGBA(factory_.get(), scaler.get());
}

std::vector<uint8_t> ImageProcessor::encode(Image image, ImageFormat format, int quality, bool lossless) {
    if (quality < 0 || quality > 100) throw std::runtime_error("Quality must be from 0 to 100");
    if (format != ImageFormat::webp) return encodeWIC(factory_.get(), image, format, quality);
    if (image.width > 16'383 || image.height > 16'383) throw std::runtime_error("WebP dimensions exceed 16383 pixels per side");
    uint8_t* encoded = nullptr;
    const size_t size = lossless
        ? WebPEncodeLosslessRGBA(image.rgba.data(), static_cast<int>(image.width), static_cast<int>(image.height),
                                  static_cast<int>(image.width * 4), &encoded)
        : WebPEncodeRGBA(image.rgba.data(), static_cast<int>(image.width), static_cast<int>(image.height),
                          static_cast<int>(image.width * 4), static_cast<float>(quality), &encoded);
    const std::unique_ptr<uint8_t, decltype(&WebPFree)> allocation(encoded, WebPFree);
    if (size == 0 || !allocation) throw std::runtime_error("WebP encoding failed");
    return {allocation.get(), allocation.get() + size};
}
