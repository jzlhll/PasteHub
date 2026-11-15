# pastehub-image

独立的 macOS 图片处理 CLI：读取单个图片文件，先调整尺寸，再编码为 PNG、JPG 或 WebP。源码、依赖和构建入口全部位于本目录，不依赖 PasteHub App 的代码、配置或签名证书；可以将 `cli/mac/` 单独复制出去构建。

## 构建

需要 macOS 13 或更新版本、Python 3 和 Apple Command Line Tools。

```bash
python3 cli/mac/build.py
```

产物为 `cli/mac/build/pastehub-image`，默认编译当前机器架构。编译采用体积优先优化，并在签名前移除运行不需要的符号信息。libwebp 静态链接，运行时仅依赖 macOS 系统库；复制这个可执行文件即可使用，无需安装 Homebrew、额外动态库或 Python。

同时支持 Apple Silicon 和 Intel 的单文件构建：

```bash
python3 cli/mac/build.py --architectures arm64 x86_64
```

可通过构建参数 `--output /路径/pastehub-image` 指定可执行文件位置。构建缓存位于本目录的 `build/`。

## 使用

```bash
# 缩放宽高至 70%，再按质量 85 编码为 JPG。
./cli/mac/build/pastehub-image --input photo.png --output result.jpg --scale 70 --quality 85

# 输出到目录，自动创建 output/，生成 photo.webp。
./cli/mac/build/pastehub-image -i photo.png -o ./output/ --format webp --quality 80

# WebP 无损编码，宽度调整为 1200，高度按比例计算。
./cli/mac/build/pastehub-image -i photo.png -o result.webp --width 1200 --lossless

# 同一路径，编码成功后替换原图。
./cli/mac/build/pastehub-image -i photo.jpg -o photo.jpg --quality 80

# 输出到输入文件所在目录，保持格式和文件名，替换同名文件。
./cli/mac/build/pastehub-image -i ./images/photo.jpg -o ./images/ --scale 70 --quality 85

./cli/mac/build/pastehub-image --help
./cli/mac/build/pastehub-image --licenses
```

| 参数 | 作用 |
| --- | --- |
| `--input` / `-i` | 必填，输入文件路径 |
| `--output` / `-o` | 必填，输出文件或目录；目录尚不存在时以 `/` 结尾 |
| `--format` / `-f` | 输出格式：`png`、`jpg` / `jpeg`、`webp` |
| `--scale` | 宽高缩放百分比，默认保持原尺寸，支持放大 |
| `--width` / `--height` | 像素尺寸；仅指定一边时保持比例，同时指定两边时使用精确尺寸 |
| `--quality` / `-q` | JPG 或有损 WebP 的整数质量，范围 0–100，默认 75 |
| `--lossless` | WebP 无损模式 |
| `--lossy` | WebP 有损模式，默认启用 |

`--scale` 与 `--width` / `--height` 互斥。不指定尺寸参数时保持解码后的原尺寸。

输出路径指向已有目录，或以 `/` 结尾时，按目录处理，文件名默认沿用输入文件名；改变格式时更换扩展名。其他路径按文件处理。输出格式优先取 `--format`，其次取输出文件扩展名；目录输出默认保持输入格式，输入格式不属于 PNG/JPG/WebP 时使用 PNG。显式格式与输出文件扩展名必须一致。目标目录自动创建，目标文件同名时直接覆盖；原图在解码和编码全部成功后才被原子替换。

PNG 固定无损，JPG 固定有损，JPG 使用 macOS 系统编码器。只有 WebP 接受 `--lossless` / `--lossy`。PNG 和无损 WebP 不接受 `--quality`，有损质量 100 仍不等于无损。

输入使用 ImageIO 解码，支持系统可读取的单帧图片，包括 PNG、JPG、WebP 和 HEIC；多帧图片拒绝处理。解码会应用 EXIF 方向，输出统一转换为 8 位 sRGB，不保留原图的 EXIF、GPS 等元数据。PNG/WebP 保留透明度，JPG 将透明区域填为白色。无损仅表示编码阶段不引入损失，尺寸调整和色彩转换仍会改变像素。WebP 每边最多 16383 像素，其他输出格式每边最多 65500 像素。

处理成功返回退出码 0，失败返回 1，错误写入标准错误输出。

## 第三方依赖

内置 libwebp 1.6.0，授权及来源见 [Vendor/libwebp/README.md](Vendor/libwebp/README.md)。许可证同时嵌入可执行文件，可通过 `--licenses` 查看。
