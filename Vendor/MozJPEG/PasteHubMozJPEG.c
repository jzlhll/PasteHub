#include "PasteHubMozJPEG.h"
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include "jpeglib.h"

typedef struct {
    struct jpeg_error_mgr manager;
    jmp_buf recovery;
    char message[JMSG_LENGTH_MAX];
} PHJPEGError;

typedef struct {
    struct jpeg_compress_struct compressor;
    PHJPEGError error;
    unsigned char *bytes;
    unsigned long size;
} PHJPEGEncoder;

static void ph_mozjpeg_error_exit(j_common_ptr info) {
    PHJPEGError *error = (PHJPEGError *)info->err;
    (*info->err->format_message)(info, error->message);
    // longjmp 仅在 C 调用栈内恢复，避免跨越 Swift 的内存管理边界。
    longjmp(error->recovery, 1);
}

int ph_mozjpeg_encode_rgba(const uint8_t *pixels, size_t width, size_t height,
                          size_t bytes_per_row, int quality,
                          uint8_t **output, size_t *output_size,
                          char *error_message, size_t error_capacity) {
    if (output == NULL || output_size == NULL) return 0;
    *output = NULL;
    *output_size = 0;
    if (error_message != NULL && error_capacity > 0) error_message[0] = '\0';
    if (pixels == NULL || width == 0 || height == 0 ||
        width > JPEG_MAX_DIMENSION || height > JPEG_MAX_DIMENSION ||
        bytes_per_row < width * 4 || height > SIZE_MAX / bytes_per_row ||
        quality < 1 || quality > 100) {
        if (error_message != NULL && error_capacity > 0)
            snprintf(error_message, error_capacity, "Invalid JPEG dimensions or quality");
        return 0;
    }

    // 编码状态放在堆上，发生 longjmp 时仍可可靠清理已分配的资源。
    PHJPEGEncoder *encoder = calloc(1, sizeof(*encoder));
    if (encoder == NULL) {
        if (error_message != NULL && error_capacity > 0)
            snprintf(error_message, error_capacity, "Cannot allocate JPEG encoder");
        return 0;
    }
    encoder->compressor.err = jpeg_std_error(&encoder->error.manager);
    encoder->error.manager.error_exit = ph_mozjpeg_error_exit;
    if (setjmp(encoder->error.recovery)) {
        if (error_message != NULL && error_capacity > 0)
            snprintf(error_message, error_capacity, "%s", encoder->error.message);
        jpeg_destroy_compress(&encoder->compressor);
        free(encoder->bytes);
        free(encoder);
        return 0;
    }

    j_compress_ptr compressor = &encoder->compressor;
    jpeg_create_compress(compressor);
    jpeg_mem_dest(compressor, &encoder->bytes, &encoder->size);
    compressor->image_width = (JDIMENSION)width;
    compressor->image_height = (JDIMENSION)height;
    compressor->input_components = 4;
    compressor->in_color_space = JCS_EXT_RGBA;
    jpeg_set_defaults(compressor);
    jpeg_set_quality(compressor, quality, TRUE);
    // 截图保留完整色度分辨率，减少彩色文字和细线边缘的模糊。
    for (int index = 0; index < compressor->num_components; index++) {
        compressor->comp_info[index].h_samp_factor = 1;
        compressor->comp_info[index].v_samp_factor = 1;
    }
    // 默认最大压缩配置已开启渐进式编码、扫描优化和 Trellis 量化。
    jpeg_start_compress(compressor, TRUE);
    while (compressor->next_scanline < compressor->image_height) {
        JSAMPROW row = (JSAMPROW)(pixels + compressor->next_scanline * bytes_per_row);
        jpeg_write_scanlines(compressor, &row, 1);
    }
    jpeg_finish_compress(compressor);
    *output = encoder->bytes;
    *output_size = (size_t)encoder->size;
    jpeg_destroy_compress(compressor);
    free(encoder);
    return 1;
}
