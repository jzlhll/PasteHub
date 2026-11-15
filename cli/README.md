# pastehub-image CLI

独立的图片处理命令行工具：输入单个图片文件，先调整尺寸，再编码输出；支持指定输出文件或目录，同名文件直接覆盖。

- [mac/README.md](mac/README.md)：已实现的 macOS 版本，包含源码、内置依赖、构建脚本及参数说明。
- [windows/README.md](windows/README.md)：Windows 版本的 C++ 实现草稿、依赖声明及构建配置，待准备依赖后编译和验证。

macOS 构建入口：

```bash
python3 cli/mac/build.py
```

可执行文件输出到 `cli/mac/build/pastehub-image`。各平台实现放在各自目录中，独立于 PasteHub App。
