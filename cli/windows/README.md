# pastehub-image Windows

独立的 Windows CLI 实现草稿，使用 C++17、Windows Imaging Component（WIC）和 libwebp，目标产物为单文件 `pastehub-image.exe`。源码和构建配置已提供，依赖准备、Windows 编译及运行验证尚待完成，目前没有可执行文件产物。

## 处理流程

读取文件到内存并关闭输入句柄 → 解码单帧图片 → 转换为 8 位 sRGB 并应用 EXIF 方向 → 调整尺寸 → 编码 → 写入同目录临时文件 → 替换目标文件。

参数、格式推断及目录输出规则与 [macOS 版本](../mac/README.md) 对应：

| 参数 | 行为 |
| --- | --- |
| `--input` / `-i` | 必填，输入文件，使用 UTF-16 Windows API 支持中文路径 |
| `--output` / `-o` | 必填，输出文件或目录；新目录以 `/` 或 `\` 结尾 |
| `--format` / `-f` | `png`、`jpg` / `jpeg`、`webp` |
| `--scale` | 宽高缩放百分比，默认保持尺寸，支持放大 |
| `--width` / `--height` | 只指定一边时保持比例，两边都指定时使用精确尺寸 |
| `--quality` / `-q` | JPG 或有损 WebP 的整数质量，0–100，默认 75 |
| `--lossless` / `--lossy` | 仅用于 WebP，默认有损 |
| `--help` / `-h` | 显示帮助 |
| `--licenses` | 显示编译时嵌入的第三方许可证 |

`--scale` 与 `--width` / `--height` 互斥。PNG 固定无损，不接受质量参数；无损 WebP 也不接受 `--quality`。有损质量 100 不等于无损。

输出格式优先取 `--format`，其次取输出文件扩展名；目录输出保持 PNG/JPG/WebP 输入格式，其他输入格式默认输出 PNG。显式格式必须与输出文件扩展名一致。输出为目录时，格式相同保留原文件名，格式变化时替换扩展名。目录自动创建，同名文件直接覆盖，允许输入输出同路径。

文件完成编码并写入临时文件后，调用 `MoveFileExW` 替换目标；失败时关闭句柄并清理本次创建的临时文件，不预先删除原图。处理成功退出码为 0，失败为 1，英文错误写入标准错误输出。

## 源码结构

- `src/main.cpp`：参数解析、路径与格式推断、尺寸计算、文件读取及替换。
- `src/ImageProcessor.cpp`：WIC / WebP 解码、EXIF 方向修正、ICC 色彩转换、缩放及编码。
- `src/WindowsSupport.hpp`：COM 会话、接口引用、文件句柄及错误处理。
- `CMakeLists.txt`：依赖查找、静态运行库、体积优化和许可证嵌入。
- `vcpkg.json`：声明 libwebp 依赖，版本最低要求由 CMake 的 `find_package(WebP 1.6 CONFIG REQUIRED)` 约束。
- `cmake/toolchains/mingw-x64.cmake`：macOS 等主机上的 Windows x64 交叉编译入口。

## 依赖

| 依赖 | 用途与要求 |
| --- | --- |
| CMake 3.24+ | 生成构建配置 |
| C++17 工具链 | Windows 上可用 MSVC 2022；交叉编译可用 MinGW-w64 |
| Windows SDK / MinGW-w64 头文件及导入库 | WIC、COM、文件与 Unicode API |
| libwebp 1.6+，静态版本 | WebP 编解码及容器元数据；需导出 `WebP::webp`、`WebP::webpdemux` CMake 目标 |
| libwebp 对应版本的授权文本 | 编译时嵌入，需包含许可证及专利授权 |

WIC 通过 Windows 系统的 `windowscodecs` 提供。MSVC 使用静态 C/C++ 运行库；MinGW 配置静态链接运行库和第三方依赖。libwebp 的间接依赖由其 CMake 目标传递，需同样使用 Windows 目标平台的静态版本。

依赖由后续开发时准备，本目录不附带 libwebp 源码或工具链，不使用 `FetchContent` 自动下载。`vcpkg.json` 仅声明包；若后续启用 vcpkg 工具链，其依赖恢复由 vcpkg 管理。MSVC 对应 `x64-windows-static`，MinGW 对应 `x64-mingw-static`，两种工具链的库不能混用。

`PASTEHUB_WEBP_NOTICE_FILE` 指向实际安装包的完整授权文本；vcpkg 安装时可自动查找 `share/libwebp/copyright`，其他安装方式需显式指定。若手工整理该文件，应合并同一版本的 `COPYING`、`PATENTS` 和必要的署名内容。缺失授权文本时配置会停止。

## 后续构建方式

以下命令仅说明依赖准备完成后的入口，示例依赖路径需按实际安装位置调整。

Windows / MSVC：

```powershell
cmake -S cli/windows -B cli/windows/build/msvc -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_PREFIX_PATH="C:/deps/webp-static" `
  -DPASTEHUB_WEBP_NOTICE_FILE="C:/deps/webp-static/share/libwebp/copyright"
cmake --build cli/windows/build/msvc --config MinSizeRel
```

预期产物：`cli/windows/build/msvc/MinSizeRel/pastehub-image.exe`。

macOS / MinGW-w64 交叉编译，要求 MinGW-w64 命令已在 `PATH` 中，且本地已有为 Windows x64 编译的 libwebp：

```bash
cmake -S cli/windows -B cli/windows/build/mingw-x64 \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/cli/windows/cmake/toolchains/mingw-x64.cmake" \
  -DCMAKE_PREFIX_PATH="$HOME/deps/webp-windows-x64" \
  -DPASTEHUB_WEBP_NOTICE_FILE="$HOME/deps/webp-windows-x64/share/libwebp/copyright"
cmake --build cli/windows/build/mingw-x64
```

预期产物：`cli/windows/build/mingw-x64/pastehub-image.exe`。

## 使用示例

```powershell
pastehub-image.exe -i photo.png -o result.jpg --scale 70 --quality 85
pastehub-image.exe -i photo.png -o ./output/ --format webp --quality 80
pastehub-image.exe -i photo.png -o result.webp --width 1200 --lossless
pastehub-image.exe -i photo.jpg -o photo.jpg --quality 80
```

## 格式与兼容性

目标系统为 Windows 10 或更新版本。PNG/JPG 使用系统 WIC；WebP 解码、编码、EXIF 和 ICC 块读取均使用 libwebp，不依赖系统 WebP 扩展。HEIC 等额外输入格式取决于本机安装的 WIC 解码器，不承诺与 macOS 的附加格式完全相同。

只处理单帧图片。PNG/WebP 保留透明度，缩放时先转换为预乘 Alpha，JPG 透明区域填白。输入按 ICC 配置转换为 8 位 sRGB；无配置时按 sRGB 解释。JPEG/TIFF 的 WIC EXIF 方向及 WebP EXIF 方向会应用到像素，输出不复制原图的 EXIF、GPS 等元数据。

WebP 每边最多 16383 像素，其他输出格式每边最多 65500 像素；内存图像还受 WIC 的 32 位缓冲区长度限制。无损仅指编码阶段，尺寸和色彩转换仍可能改变像素。

Windows 使用 WIC 缩放和 JPG 编码，与 macOS 的 CoreGraphics / ImageIO 不保证逐像素或逐字节一致，质量数值也不代表保留信息的百分比。Windows 构建、输入格式、元数据、中文路径、覆盖行为及最终动态依赖仍需在准备好环境后核实。

接口依据：[WIC 缩放](https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nf-wincodec-iwicbitmapscaler-initialize)、[WIC 色彩转换](https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nf-wincodec-iwiccolortransform-initialize)、[JPEG 质量参数](https://learn.microsoft.com/en-us/windows/win32/wic/jpeg-format-overview)、[libwebp 构建说明](https://github.com/webmproject/libwebp/blob/v1.6.0/doc/building.md)。
