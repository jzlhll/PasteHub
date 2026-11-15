package top.yayalu.imagecodec;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.ColorSpace;
import android.os.Build;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

/** 图片转换入口，共用核心负责尺寸调整与 WebP 编码，平台负责图片解码及 PNG/JPG 编码。 */
public final class ImageCodec {
    public static final int FORMAT_PNG = 1;
    public static final int FORMAT_JPEG = 2;
    public static final int FORMAT_WEBP = 3;

    static { System.loadLibrary("pastehub_image"); }

    private ImageCodec() {}

    /** 原生 C/C++ 调用方可先调用此入口，触发库加载和平台编码器初始化。 */
    public static void initialize() {}

    public static final class Options {
        public int format = FORMAT_JPEG;
        public int width;
        public int height;
        public double scalePercent = 100;
        public int quality = 75;
        public boolean webpLossless;
    }

    /** 在调用线程执行，较大图片应由调用方放到后台线程处理。 */
    public static byte[] convert(byte[] data, Options options) {
        if (data == null || data.length == 0 || options == null) throw new IllegalArgumentException("Image data and options are required");
        return nativeConvert(data, options.format, options.width, options.height, options.scalePercent, options.quality, options.webpLossless);
    }

    /** 直接处理 Bitmap，不先进行 JPG/PNG 中间编码，也不回收调用方的 Bitmap。 */
    public static byte[] encode(Bitmap bitmap, Options options) {
        if (bitmap == null || bitmap.isRecycled() || options == null) throw new IllegalArgumentException("Bitmap and options are required");
        Bitmap normalized = normalize(bitmap);
        try {
            return nativeBitmap(normalized, options.format, options.width, options.height, options.scalePercent, options.quality, options.webpLossless);
        } finally {
            if (normalized != bitmap) normalized.recycle();
        }
    }

    private static Bitmap normalize(Bitmap bitmap) {
        boolean srgb = Build.VERSION.SDK_INT < 26 || bitmap.getColorSpace() == null || bitmap.getColorSpace().isSrgb();
        if (bitmap.getConfig() == Bitmap.Config.ARGB_8888 && srgb) return bitmap;
        Bitmap software = bitmap;
        if (Build.VERSION.SDK_INT >= 26 && bitmap.getConfig() == Bitmap.Config.HARDWARE) {
            software = bitmap.copy(Bitmap.Config.ARGB_8888, false);
            if (software == null) throw new IllegalStateException("Cannot copy hardware Bitmap");
        }
        try {
            long count = (long) bitmap.getWidth() * bitmap.getHeight();
            if (count > Integer.MAX_VALUE) throw new IllegalArgumentException("Bitmap is too large");
            int[] pixels = new int[(int) count];
            software.getPixels(pixels, 0, bitmap.getWidth(), 0, 0, bitmap.getWidth(), bitmap.getHeight());
            return Bitmap.createBitmap(pixels, bitmap.getWidth(), bitmap.getHeight(), Bitmap.Config.ARGB_8888);
        } finally {
            if (software != bitmap) software.recycle();
        }
    }

    private static Bitmap decodeForNative(byte[] data) {
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inPreferredConfig = Bitmap.Config.ARGB_8888;
        options.inPremultiplied = false;
        options.inScaled = false;
        if (Build.VERSION.SDK_INT >= 26) options.inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB);
        Bitmap bitmap = BitmapFactory.decodeByteArray(data, 0, data.length, options);
        if (bitmap == null) throw new IllegalArgumentException("Unsupported or invalid image data");
        return bitmap;
    }

    private static byte[] encodeForNative(byte[] rgba, int width, int height, int format, int quality) {
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        try {
            bitmap.setPremultiplied(false);
            bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba));
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            Bitmap.CompressFormat compression = format == FORMAT_PNG ? Bitmap.CompressFormat.PNG : Bitmap.CompressFormat.JPEG;
            if (!bitmap.compress(compression, quality, output)) throw new IllegalStateException("Bitmap encoding failed");
            return output.toByteArray();
        } finally {
            bitmap.recycle();
        }
    }

    private static native byte[] nativeConvert(byte[] data, int format, int width, int height, double scale, int quality, boolean lossless);
    private static native byte[] nativeBitmap(Bitmap bitmap, int format, int width, int height, double scale, int quality, boolean lossless);
}
