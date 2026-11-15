# libwebp

内置上游 libwebp 1.6.0，来源为 [v1.6.0](https://chromium.googlesource.com/webm/libwebp/+/refs/tags/v1.6.0)。归档 SHA-256 为 `93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136`。

四个平台共用同一份编码器、DSP、工具函数和 SharpYUV 源码；Windows 适配额外编译解码器及 demux，以支持不依赖系统扩展的 WebP 解码。上游 C 源码及头文件不作修改。

[COPYING](COPYING)、[PATENTS](PATENTS)、[AUTHORS](AUTHORS) 随静态库安装并打包进 AAR，授权文本也可通过 `ph_image_third_party_notices()` 获取。
