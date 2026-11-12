# MozJPEG

- 上游：[mozilla/mozjpeg v4.1.5](https://github.com/mozilla/mozjpeg/tree/v4.1.5)，提交 `38f37cf900958c1004c2eea945a773764ba20716`。
- `src/` 保留上游 `CMakeLists.txt` 中 `JPEG_SOURCES` 的 49 个 C 文件、`jsimd_none.c`、头文件及其直接包含的 C 片段；上游源码不作修改。C 片段放在 `src/include/`，不单独编译。
- `jconfig.h`、`jconfigint.h` 为 Apple Clang 的 64 位 macOS 配置，`jversion.h` 根据上游模板生成。采用通用 C 实现，不需要 CMake、额外汇编器或运行时动态库。
- `PasteHubMozJPEG.c` 提供 RGBA 像素到内存 JPG 的编码入口，将 `setjmp` 错误恢复限制在 C 内，并负责异常时释放资源。
- `scripts/build_mozjpeg.py` 使用 Command Line Tools 编译静态库，支持 arm64 和 x86_64；Xcode 与 `scripts/build_macos.py` 共用该入口。只将最终使用到的代码链接进应用。
- 命令行产物缓存在 `build/MozJPEG/`，Xcode 产物缓存在目标的 `TARGET_TEMP_DIR/MozJPEG/`。以 C 源码、头文件、构建脚本及架构、SDK、编译器版本、最低系统版本计算内容指纹；指纹未变化时复用静态库，清理构建目录后首次构建会重新编译。
- 「设置 → 通用 → 截图导出」提供全局 MozJPEG 开关，默认开启并持久化；关闭后使用系统 JPG 编码器。高档质量为 75，低档质量为 72 且尺寸缩放为 70%，自定义 JPG 质量范围为 60–85、默认 75。MozJPEG 直接使用该质量值编码一次，采用默认最大压缩配置（渐进式、扫描优化、Trellis 量化），并将色度采样设为 4:4:4，保留文字及细线的色彩边缘。
- [LICENSE.md](LICENSE.md) 和 [README.ijg](README.ijg) 保留上游授权。分发包携带 `PasteHub/Resources/ThirdPartyNotices.txt`。
