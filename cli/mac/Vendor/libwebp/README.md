# libwebp

- 版本：1.6.0，上游标签 [v1.6.0](https://chromium.googlesource.com/webm/libwebp/+/refs/tags/v1.6.0)。
- 下载来源：[上游 GitHub 镜像源码归档](https://codeload.github.com/webmproject/libwebp/tar.gz/refs/tags/v1.6.0)。归档 SHA-256：`93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136`。
- 保留 `src/enc/`、`src/dsp/`、`src/utils/`、`sharpyuv/` 的 C 文件及 `src/`、`sharpyuv/` 的头文件，上游源码未修改。解码使用 macOS ImageIO，未引入 libwebp 解码器及动画封装。
- `cli/mac/build.py` 使用 Apple Clang 编译并静态链接，启用平台默认的 SIMD 和线程支持，不依赖 CMake、Homebrew 或网络下载。
- [COPYING](COPYING)、[PATENTS](PATENTS)、[AUTHORS](AUTHORS) 保留上游授权与署名，同时嵌入最终可执行文件。
