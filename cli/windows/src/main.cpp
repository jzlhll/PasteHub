#include "ImageProcessor.hpp"
#include "ThirdPartyNotices.hpp"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cwchar>
#include <filesystem>
#include <iostream>
#include <limits>
#include <optional>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

struct Options {
    std::wstring input;
    std::wstring output;
    std::optional<ImageFormat> format;
    std::optional<double> scale;
    std::optional<UINT> width;
    std::optional<UINT> height;
    int quality = 75;
    bool hasQuality = false;
    std::optional<bool> lossless;
};

const char* formatName(ImageFormat format) {
    switch (format) {
    case ImageFormat::png: return "png";
    case ImageFormat::jpg: return "jpg";
    case ImageFormat::webp: return "webp";
    }
    throw std::runtime_error("Invalid output format");
}

std::optional<ImageFormat> parseFormat(std::wstring text) {
    for (auto& character : text) {
        if (character >= L'A' && character <= L'Z') character += L'a' - L'A';
    }
    if (text == L"png") return ImageFormat::png;
    if (text == L"jpg" || text == L"jpeg") return ImageFormat::jpg;
    if (text == L"webp") return ImageFormat::webp;
    return std::nullopt;
}

std::optional<ImageFormat> extensionFormat(const fs::path& path) {
    const auto extension = path.extension().wstring();
    return extension.empty() ? std::nullopt : parseFormat(extension.substr(1));
}

unsigned parseInteger(const std::wstring& text, unsigned minimum, unsigned maximum, const char* option) {
    const auto input = utf8(text);
    unsigned result = 0;
    const auto parsed = std::from_chars(input.data(), input.data() + input.size(), result);
    if (parsed.ec != std::errc{} || parsed.ptr != input.data() + input.size()
        || result < minimum || result > maximum) {
        throw std::runtime_error(std::string(option) + " must be an integer from "
                                 + std::to_string(minimum) + " to " + std::to_string(maximum));
    }
    return result;
}

Options parseOptions(int count, wchar_t** arguments) {
    Options options;
    for (int index = 1; index < count; ++index) {
        const std::wstring argument = arguments[index];
        const auto value = [&]() -> std::wstring {
            if (++index >= count) throw std::runtime_error("Missing value for " + utf8(argument));
            return arguments[index];
        };
        if (argument == L"--input" || argument == L"-i") {
            options.input = value();
        } else if (argument == L"--output" || argument == L"-o") {
            options.output = value();
        } else if (argument == L"--format" || argument == L"-f") {
            const auto text = value();
            options.format = parseFormat(text);
            if (!options.format) throw std::runtime_error("Unsupported output format: " + utf8(text));
        } else if (argument == L"--scale") {
            const auto text = utf8(value());
            char* end = nullptr;
            const double scale = std::strtod(text.c_str(), &end);
            if (text.empty() || end != text.c_str() + text.size() || !std::isfinite(scale) || scale <= 0) {
                throw std::runtime_error("--scale must be a positive percentage");
            }
            options.scale = scale;
        } else if (argument == L"--width" || argument == L"--height") {
            const auto number = parseInteger(value(), 1, std::numeric_limits<UINT>::max(), "Image dimension");
            if (argument == L"--width") options.width = number; else options.height = number;
        } else if (argument == L"--quality" || argument == L"-q") {
            options.quality = static_cast<int>(parseInteger(value(), 0, 100, "--quality"));
            options.hasQuality = true;
        } else if (argument == L"--lossless" || argument == L"--lossy") {
            const bool lossless = argument == L"--lossless";
            if (options.lossless.has_value() && *options.lossless != lossless) {
                throw std::runtime_error("--lossless and --lossy cannot be used together");
            }
            options.lossless = lossless;
        } else {
            throw std::runtime_error("Unknown argument: " + utf8(argument) + ". Use --help for usage.");
        }
    }
    if (options.input.empty() || options.output.empty()) {
        throw std::runtime_error("Both --input and --output are required");
    }
    if (options.scale && (options.width || options.height)) {
        throw std::runtime_error("Use either --scale or --width/--height");
    }
    return options;
}

fs::path filePath(std::wstring text) {
    if (text == L"~" || (text.size() > 1 && text[0] == L'~' && (text[1] == L'/' || text[1] == L'\\'))) {
        const DWORD count = GetEnvironmentVariableW(L"USERPROFILE", nullptr, 0);
        if (count == 0) failWin32("Read user profile path");
        std::vector<wchar_t> profile(count);
        const DWORD written = GetEnvironmentVariableW(L"USERPROFILE", profile.data(), count);
        if (written == 0 || written >= count) throw std::runtime_error("Cannot read user profile path");
        text = std::wstring(profile.data()) + text.substr(1);
    }
    return fs::absolute(fs::path(text)).lexically_normal();
}

std::pair<fs::path, ImageFormat> outputTarget(const Options& options, const fs::path& input,
                                             const std::optional<ImageFormat>& inputFormat) {
    const auto output = filePath(options.output);
    const bool trailingSeparator = options.output.back() == L'/' || options.output.back() == L'\\';
    const bool exists = fs::exists(output);
    const bool directory = (exists && fs::is_directory(output)) || trailingSeparator;
    if (exists && !fs::is_directory(output) && directory) {
        throw std::runtime_error("Output directory is an existing file: " + utf8(output.wstring()));
    }
    ImageFormat format;
    if (options.format) {
        format = *options.format;
        if (!directory && output.has_extension() && extensionFormat(output) != options.format) {
            throw std::runtime_error("Output extension does not match --format " + std::string(formatName(format)));
        }
    } else if (!directory && output.has_extension()) {
        const auto inferred = extensionFormat(output);
        if (!inferred) throw std::runtime_error("Unsupported output extension: " + utf8(output.extension().wstring()));
        format = *inferred;
    } else {
        format = inputFormat.value_or(ImageFormat::png);
    }
    if (options.lossless.has_value() && format != ImageFormat::webp) {
        throw std::runtime_error("--lossless and --lossy apply only to WebP");
    }
    if (options.hasQuality && (format == ImageFormat::png || options.lossless.value_or(false))) {
        throw std::runtime_error("--quality applies only to JPG or lossy WebP");
    }
    if (!directory) return {output, format};
    auto filename = input.filename();
    if (extensionFormat(input) != format) filename.replace_extension(std::string(".") + formatName(format));
    return {output / filename, format};
}

std::pair<UINT, UINT> dimensions(const Image& image, const Options& options, ImageFormat format) {
    double width = image.width;
    double height = image.height;
    if (options.scale) {
        width *= *options.scale / 100;
        height *= *options.scale / 100;
    } else if (options.width && options.height) {
        width = *options.width;
        height = *options.height;
    } else if (options.width) {
        height *= static_cast<double>(*options.width) / width;
        width = *options.width;
    } else if (options.height) {
        width *= static_cast<double>(*options.height) / height;
        height = *options.height;
    }
    const double limit = format == ImageFormat::webp ? 16'383 : 65'500;
    if (!std::isfinite(width) || !std::isfinite(height) || std::round(width) > limit || std::round(height) > limit) {
        throw std::runtime_error("Output dimensions exceed the " + std::to_string(static_cast<int>(limit))
                                 + "-pixel limit per side for " + formatName(format));
    }
    return {static_cast<UINT>(std::max(1.0, std::round(width))),
            static_cast<UINT>(std::max(1.0, std::round(height)))};
}

std::vector<uint8_t> readFile(const fs::path& path) {
    if (!fs::is_regular_file(path)) throw std::runtime_error("Input must be an existing file: " + utf8(path.wstring()));
    FileHandle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL, nullptr));
    LARGE_INTEGER length{};
    if (!GetFileSizeEx(file.get(), &length)) failWin32("Read input size");
    if (length.QuadPart <= 0 || static_cast<uint64_t>(length.QuadPart) > std::numeric_limits<UINT>::max()) {
        throw std::runtime_error("Input is empty or exceeds the supported 4 GiB buffer size");
    }
    std::vector<uint8_t> data(static_cast<size_t>(length.QuadPart));
    size_t offset = 0;
    while (offset < data.size()) {
        const DWORD count = static_cast<DWORD>(std::min<size_t>(data.size() - offset, 1024 * 1024));
        DWORD read = 0;
        if (!ReadFile(file.get(), data.data() + offset, count, &read, nullptr)) failWin32("Read input image");
        if (read == 0) throw std::runtime_error("Input file ended before its declared size");
        offset += read;
    }
    // 返回前关闭输入句柄，使同路径替换不受本进程的文件占用影响。
    return data;
}

void writeFile(const fs::path& output, const std::vector<uint8_t>& data) {
    fs::create_directories(output.parent_path());
    GUID identifier{};
    checkHRESULT(CoCreateGuid(&identifier), "Create temporary file identifier");
    wchar_t identifierText[40]{};
    if (StringFromGUID2(identifier, identifierText, 40) == 0) throw std::runtime_error("Cannot format temporary file identifier");
    const auto temporary = output.parent_path() / (std::wstring(L".pastehub-image-") + identifierText + L".tmp");
    // 清理对象先于句柄创建，异常退出时先关闭句柄，再删除临时文件。
    struct TemporaryFile {
        fs::path path;
        bool created = false;
        bool committed = false;
        ~TemporaryFile() { if (created && !committed) DeleteFileW(path.c_str()); }
    } cleanup{temporary};
    FileHandle file(CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                                FILE_ATTRIBUTE_NORMAL, nullptr));
    cleanup.created = true;
    size_t offset = 0;
    while (offset < data.size()) {
        const DWORD count = static_cast<DWORD>(std::min<size_t>(data.size() - offset, 1024 * 1024));
        DWORD written = 0;
        if (!WriteFile(file.get(), data.data() + offset, count, &written, nullptr)) failWin32("Write output image");
        if (written == 0) throw std::runtime_error("Output write made no progress");
        offset += written;
    }
    if (!FlushFileBuffers(file.get())) failWin32("Flush output image");
    file.close();
    if (!MoveFileExW(temporary.c_str(), output.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        failWin32("Replace output image");
    }
    cleanup.committed = true;
}

void process(const Options& options) {
    const auto input = filePath(options.input);
    ImageProcessor processor;
    auto decoded = processor.decode(readFile(input));
    const auto [output, format] = outputTarget(options, input, decoded.format);
    const auto [width, height] = dimensions(decoded.pixels, options, format);
    const auto originalWidth = decoded.pixels.width;
    const auto originalHeight = decoded.pixels.height;
    auto resized = processor.resize(std::move(decoded.pixels), width, height);
    const auto encoded = processor.encode(std::move(resized), format, options.quality, options.lossless.value_or(false));
    writeFile(output, encoded);
    const std::string mode = format == ImageFormat::png || options.lossless.value_or(false)
        ? "lossless" : "lossy, quality " + std::to_string(options.quality);
    std::cout << "Saved: " << utf8(output.wstring()) << '\n'
              << "Size: " << originalWidth << 'x' << originalHeight << " -> " << width << 'x' << height
              << ", " << formatName(format) << ", " << mode << ", " << encoded.size() << " bytes\n";
}

constexpr const char* help = R"HELP(用法：pastehub-image.exe --input <文件> --output <文件或目录> [选项]

读取单张图片，先调整尺寸，再编码；目标文件存在时直接覆盖。

  -i, --input <路径>       输入图片文件，支持中文路径
  -o, --output <路径>      输出文件或目录；末尾带 / 或 \ 可创建目录
  -f, --format <格式>      png、jpg（或 jpeg）、webp
      --scale <百分比>     宽高缩放百分比，例如 70
      --width <像素>       目标宽度；只指定一边时保持比例
      --height <像素>      目标高度；同时指定两边时使用精确尺寸
  -q, --quality <0–100>    JPG / 有损 WebP 的质量，默认 75
      --lossless          WebP 无损模式，不接受 --quality
      --lossy             WebP 有损模式（默认）
  -h, --help              显示帮助
      --licenses          显示第三方许可证

--scale 与 --width / --height 互斥。
输出文件按扩展名确定格式；目录输出默认保持输入格式，其他输入格式输出 PNG。
可用 --format 显式指定格式。PNG 固定无损，不接受 --quality。
PNG/WebP 保留透明度，JPG 透明区域填白。只处理单帧图片。
无损指编码阶段无损，尺寸调整及 8 位 sRGB 色彩转换仍可能改变像素。
)HELP";

}

int wmain(int count, wchar_t** arguments) {
    SetConsoleOutputCP(CP_UTF8);
    try {
        if (count == 1) { std::cout << help; return 0; }
        for (int index = 1; index < count; ++index) {
            if (std::wcscmp(arguments[index], L"--help") == 0 || std::wcscmp(arguments[index], L"-h") == 0) {
                std::cout << help;
                return 0;
            }
        }
        if (count == 2 && std::wcscmp(arguments[1], L"--licenses") == 0) {
            std::cout << kThirdPartyNotices;
            return 0;
        }
        process(parseOptions(count, arguments));
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Error: " << error.what() << '\n';
        return 1;
    }
}
