# PasteHubImage

Windows、iOS、macOS、Android 共用的图片处理库。公共接口采用 C ABI，不暴露 C++ 对象、异常或平台图片类型；原始像素接口统一接收非预乘 Alpha 的 8 位 sRGB RGBA。

共用处理顺序为解码 → 尺寸计算 → 带 Alpha 的抗混叠缩放 → 格式编码。JPG 的透明区域统一铺白；WebP 编码统一使用内置 libwebp 1.6.0，可选有损或无损。PNG 固定无损。编码期间不再经过其他有损格式的中间转码。

## 平台分工

| 内容 | 共用部分 / 平台适配 |
| --- | --- |
| C 接口与内存管理 | `include/pastehub_image.h`、`src/pastehub_image.cpp` |
| 参数校验、尺寸计算、缩放、JPG 铺底 | 共用 C++ 核心 |
| WebP 有损 / 无损编码 | 共用 libwebp |
| EXIF 方向工具 | 共用工具，解码适配负责避免重复应用方向 |
| macOS / iOS | Apple ImageIO + CoreGraphics，同一份适配源码 |
| Windows | WIC；WebP 解码和元数据通过 libwebp + demux 处理 |
| Android | BitmapFactory / Bitmap + JNI；原始 Bitmap 可直接传入，无需先编码 |

PNG/JPG 编码及附加输入格式取决于平台，因此跨平台不承诺同一质量参数生成完全相同的字节。缩放及 WebP 编码使用同一套核心；无损仅表示编码阶段无损，缩放、解码、色彩转换和 Alpha 格式转换仍可能改变像素。

## 公共 C 接口

```c
#include "pastehub_image.h"

PHImageOptions options;
ph_image_options_init(&options);
options.format = PH_IMAGE_WEBP;
options.scale_percent = 70;
options.quality = 85;

PHImageBuffer result = {0};
char error[512] = {0};
PHImageStatus status = ph_image_convert(input_bytes, input_size, &options,
                                       &result, error, sizeof(error));
if (status == PH_IMAGE_OK) {
    // 使用 result.data、result.size、result.width 和 result.height。
}
ph_image_buffer_free(&result);
```

- `ph_image_convert`：输入编码后的图片数据，使用平台解码器处理。
- `ph_image_encode_rgba`：输入原始 RGBA、宽高及 stride，直接缩放和编码。
- `ph_image_options_init`：默认 JPG、原尺寸、质量 75。应先调用，再修改所需字段。
- `ph_image_buffer_free`：释放输出，并清零结构体。输出结构体首次使用前必须清零，重复调用前应释放上一次结果，不能用调用方的 `free` 替代。
- `ph_image_third_party_notices`：返回库内授权文本，指针不需要释放。

质量范围 0–100，仅影响 JPG 和有损 WebP；PNG / 无损 WebP 忽略该值。`webp_lossless` 只能用于 WebP。宽高都为零时使用 `scale_percent`；只指定一边则保持比例，两边都指定则使用精确尺寸。指定宽高时 `scale_percent` 必须保持默认的 100。

WebP 每边最多 16383 像素，其他格式每边最多 65500 像素，实际还受平台缓冲区及可用内存限制。公共函数同步执行，错误通过返回状态和调用方的错误缓冲区报告，不依赖全局错误状态。

## macOS 静态库与动态库

需要 Apple Command Line Tools 和 CMake 3.22+；Ninja 可选。

```bash
python3 image-library/scripts/build_apple.py
```

若 CMake / Ninja 不在 PATH 中，可显式传入 `--cmake` 和 `--ninja`。

交付目录为 `image-library/dist/macos/`：

- `lib/libPasteHubImage.a`：包含 arm64 和 x86_64，内置 libwebp 对象。
- `lib/libPasteHubImage.dylib`：同样包含双架构及 libwebp，仅导出公共 C 接口，install name 为 `@rpath/libPasteHubImage.dylib`，可由 JNA 等运行时直接加载。
- `include/pastehub_image.h`：C / C++ 接口。
- `include/module.modulemap`：Swift Clang 模块导入配置。
- `share/licenses/libwebp/`：第三方授权。

静态链接时，调用方链接 `PasteHubImage`、系统 `c++`、`CoreFoundation`、`CoreGraphics`、`ImageIO`。动态加载时只需分发 `.dylib` 和第三方授权文件，库仅依赖 macOS 系统框架，不要求调用方另行分发 libwebp。Swift 可配置头文件搜索路径和库搜索路径后 `import PasteHubImage`，也可通过 bridging header 引入 C 头文件。静态库不能像可执行文件一样移除所有符号，公共 C 符号需保留供调用方链接。

## Android AAR

项目使用 AGP 9.4.0、Gradle 9.6.0、JDK 17、NDK 27.1.12297006、CMake 3.30.5、compileSdk 35，最低支持 Android 5.0（API 21）。Gradle Wrapper 使用指定镜像：

```text
https://mirrors.cloud.tencent.com/gradle/gradle-9.6.0-bin.zip
```

配置 `ANDROID_HOME` / `ANDROID_SDK_ROOT`，或提供 `--sdk`：

```bash
python3 image-library/scripts/build_android.py --sdk "$HOME/Library/Android/sdk"
```

网络无法访问 Google Maven 时可追加 `--maven-mirror https://maven.aliyun.com/repository`。已有完整缓存时可用 `--offline`。

交付文件为 `image-library/dist/android/pastehub-image-1.0.0.aar`，包含 Java API、consumer ProGuard 规则、授权文件、两种 ARM ABI 的共享库和 Prefab C 接口：`arm64-v8a`、`armeabi-v7a`。C++ 运行库静态链接，64 位 ELF 使用 16 KiB 页面兼容配置。

Java 调用示例：

```java
ImageCodec.Options options = new ImageCodec.Options();
options.format = ImageCodec.FORMAT_WEBP;
options.scalePercent = 70;
options.quality = 85;
byte[] encoded = ImageCodec.convert(inputBytes, options);

// 截图已有 Bitmap 时直接处理，避免先编码一次。
byte[] bitmapEncoded = ImageCodec.encode(bitmap, options);
```

类名为 `top.yayalu.imagecodec.ImageCodec`。调用在当前线程执行，较大图片应由宿主安排后台线程。调用方的 Bitmap 不会被回收。硬件 Bitmap 和非 ARGB_8888 输入会转换为软件像素；Android 8+ 解码请求 sRGB，较早系统的色彩支持取决于系统解码器。

JNI 在 `JNI_OnLoad` 中显式注册方法，保留规则避免混淆破坏类名和平台回调。直接从宿主 C/C++ 调用 Prefab 接口时，需先从 Java 调用 `ImageCodec.initialize()`，为 PNG/JPG 平台编解码器初始化 JVM 桥接；`JNIEnv` 按调用线程获取，不跨线程复用。

原生宿主开启 `buildFeatures.prefab` 后，CMake 可使用 `find_package(imagecodec CONFIG REQUIRED)` 和 `imagecodec::PasteHubImage`。发布构建只导出公共 C 接口及 JNI 加载入口，去除调试和内部符号；Prefab 与 Java 使用相同的 `.so`，不额外携带一份含调试信息的库。

## Windows DLL

需要在 Windows 安装 Python 3、CMake 3.22+、Visual Studio C++ 桌面组件及目标架构的 x64 / ARM64 工具链，在 PasteHub 仓库根目录执行：

```powershell
python image-library/scripts/build_windows.py --arch x64
python image-library/scripts/build_windows.py --arch arm64
```

`--arch` 默认使用本机架构；CMake 不在 PATH 中时传入 `--cmake`，需要指定 Visual Studio 版本时传入 `--generator`。脚本启用 `BUILD_SHARED_LIBS=ON`，以 MinSizeRel 配置构建，各架构的构建目录和交付目录独立。

交付目录为 `image-library/dist/windows-x64/` 或 `image-library/dist/windows-arm64/`：

- `bin/PasteHubImage.dll`：包含共用核心、Windows 适配及 libwebp，C/C++ 运行库静态链接，供 JNA 等宿主动态加载。
- `lib/PasteHubImage.lib`：供原生宿主链接的导入库。
- `include/pastehub_image.h`：公共 C 接口。
- `share/licenses/libwebp/`：第三方授权。

宿主仓库只接收与目标架构匹配的实体 DLL 和授权文件，随安装包分发；宿主的编译流程无需本仓库源码或 C++ 工具链。需要更新动态库时，在本仓库生成产物后再复制到宿主资源目录。Windows DLL 尚待在对应 Windows 系统完成构建和运行验证。

直接用 CMake 构建时，默认仍为静态库，可显式设置 `-DBUILD_SHARED_LIBS=ON` 生成 DLL。静态链接宿主需使用匹配的架构和 C/C++ 运行库配置，并链接 WIC、COM 等系统库。

## iOS 静态库

iOS 使用 Apple 适配和同一 C 接口；具备 Xcode / iOS SDK 后，可通过 `build_apple.py --platform ios` 或 `--platform ios-simulator` 构建。设备与模拟器分别输出，不能把相同 arm64 架构的设备和模拟器库直接合并为同一个 fat `.a`。iOS 本次不构建或安装验证。

既有 `cli/` 仍保留为独立命令行工具；本目录是供 App 链接调用的 SDK，不依赖 PasteHub App 的代码或签名配置。
