#ifndef PASTE_HUB_MOZ_JPEG_H
#define PASTE_HUB_MOZ_JPEG_H

#include <stddef.h>
#include <stdint.h>

// 输入不透明的 RGBA 像素；成功时输出由 malloc 分配，交由调用方释放。
int ph_mozjpeg_encode_rgba(const uint8_t *pixels, size_t width, size_t height,
                          size_t bytes_per_row, int quality,
                          uint8_t **output, size_t *output_size,
                          char *error_message, size_t error_capacity);

#endif
