#include "internal.hpp"

#include <android/bitmap.h>
#include <jni.h>

#include <algorithm>
#include <cstring>
#include <limits>

namespace {

JavaVM* javaVM = nullptr;
jclass codecClass = nullptr;
jmethodID decodeMethod = nullptr;
jmethodID encodeMethod = nullptr;
jmethodID premultipliedMethod = nullptr;
jmethodID recycleMethod = nullptr;

// 按当前线程获取 JNIEnv，只分离由库主动附加的原生线程。
class Environment {
public:
    Environment() {
        if (!javaVM) throw ph::Error(PH_IMAGE_PLATFORM_ERROR, "Load the Android library through ImageCodec before using platform codecs");
        const jint result = javaVM->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
        if (result == JNI_EDETACHED) {
            if (javaVM->AttachCurrentThread(&env, nullptr) != JNI_OK) throw ph::Error(PH_IMAGE_PLATFORM_ERROR, "Cannot attach native thread to JVM");
            attached = true;
        } else if (result != JNI_OK) {
            throw ph::Error(PH_IMAGE_PLATFORM_ERROR, "Cannot obtain JNI environment");
        }
    }
    ~Environment() { if (attached) javaVM->DetachCurrentThread(); }
    JNIEnv* env = nullptr;
private:
    bool attached = false;
};

// 释放 JNI 局部引用，避免原生线程调用 C 接口时累积引用。
template <typename T>
class LocalReference {
public:
    LocalReference(JNIEnv* env, T value) : env(env), value(value) {}
    ~LocalReference() { if (value) env->DeleteLocalRef(value); }
    T get() const { return value; }
    LocalReference(const LocalReference&) = delete;
    LocalReference& operator=(const LocalReference&) = delete;
private:
    JNIEnv* env;
    T value;
};

void check_java(JNIEnv* env, const char* operation) {
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        throw ph::Error(PH_IMAGE_PLATFORM_ERROR, operation);
    }
}

jbyteArray byte_array(JNIEnv* env, const uint8_t* data, size_t size) {
    if (size > static_cast<size_t>(std::numeric_limits<jsize>::max())) throw ph::Error(PH_IMAGE_INVALID_ARGUMENT, "Image exceeds Java array size limit");
    auto result = env->NewByteArray(static_cast<jsize>(size));
    check_java(env, "Cannot allocate Java byte array");
    if (!result) throw std::bad_alloc();
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(size), reinterpret_cast<const jbyte*>(data));
    check_java(env, "Cannot copy Java image data");
    return result;
}

std::vector<uint8_t> array_bytes(JNIEnv* env, jbyteArray array) {
    if (!array) throw ph::Error(PH_IMAGE_PLATFORM_ERROR, "Platform image codec returned no data");
    const jsize size = env->GetArrayLength(array);
    std::vector<uint8_t> result(static_cast<size_t>(size));
    env->GetByteArrayRegion(array, 0, size, reinterpret_cast<jbyte*>(result.data()));
    check_java(env, "Cannot read Java image data");
    return result;
}

ph::Image bitmap_pixels(JNIEnv* env, jobject bitmap) {
    if (!bitmap) throw ph::Error(PH_IMAGE_DECODE_FAILED, "Bitmap is required");
    AndroidBitmapInfo info{};
    if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS
        || info.format != ANDROID_BITMAP_FORMAT_RGBA_8888) {
        throw ph::Error(PH_IMAGE_DECODE_FAILED, "Bitmap must use software ARGB_8888 pixels");
    }
    const bool premultiplied = env->CallBooleanMethod(bitmap, premultipliedMethod);
    check_java(env, "Cannot read Bitmap alpha mode");
    ph::Image image{info.width, info.height, std::vector<uint8_t>(ph::image_bytes(info.width, info.height))};
    void* pixels = nullptr;
    if (AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS) {
        throw ph::Error(PH_IMAGE_DECODE_FAILED, "Cannot lock Bitmap pixels");
    }
    struct PixelUnlock {
        JNIEnv* env;
        jobject bitmap;
        ~PixelUnlock() { AndroidBitmap_unlockPixels(env, bitmap); }
    } unlock{env, bitmap};
    const size_t row = static_cast<size_t>(image.width) * 4;
    for (uint32_t y = 0; y < image.height; ++y) {
        std::memcpy(image.rgba.data() + row * y, static_cast<const uint8_t*>(pixels) + static_cast<size_t>(info.stride) * y, row);
    }
    if (premultiplied) {
        for (size_t offset = 0; offset < image.rgba.size(); offset += 4) {
            const unsigned alpha = image.rgba[offset + 3];
            if (alpha == 255) continue;
            for (unsigned channel = 0; channel < 3; ++channel) {
                image.rgba[offset + channel] = alpha == 0 ? 0 : static_cast<uint8_t>(std::min(255u, (image.rgba[offset + channel] * 255u + alpha / 2) / alpha));
            }
        }
    }
    return image;
}

PHImageOptions image_options(jint format, jint width, jint height, jdouble scale, jint quality, jboolean lossless) {
    if (width < 0 || height < 0) throw ph::Error(PH_IMAGE_INVALID_ARGUMENT, "Dimensions cannot be negative");
    PHImageOptions options;
    ph_image_options_init(&options);
    options.format = static_cast<PHImageFormat>(format);
    options.width = static_cast<uint32_t>(width);
    options.height = static_cast<uint32_t>(height);
    options.scale_percent = scale;
    options.quality = quality;
    options.webp_lossless = lossless ? 1 : 0;
    return options;
}

void throw_java(JNIEnv* env, const char* message, bool argument = false) {
    if (env->ExceptionCheck()) return;
    LocalReference<jclass> type(env, env->FindClass(argument ? "java/lang/IllegalArgumentException" : "java/lang/IllegalStateException"));
    if (type.get()) env->ThrowNew(type.get(), message);
}

template <typename Function>
jbyteArray native_call(JNIEnv* env, Function function) {
    PHImageBuffer output{};
    struct BufferRelease { PHImageBuffer* buffer; ~BufferRelease() { ph_image_buffer_free(buffer); } } release{&output};
    try {
        char error[512]{};
        const PHImageStatus status = function(output, error, sizeof(error));
        if (status != PH_IMAGE_OK) {
            throw_java(env, error, status == PH_IMAGE_INVALID_ARGUMENT);
            return nullptr;
        }
        return byte_array(env, output.data, output.size);
    } catch (const std::exception& error) {
        throw_java(env, error.what());
        return nullptr;
    } catch (...) {
        throw_java(env, "Unknown native image error");
        return nullptr;
    }
}

jbyteArray native_convert(JNIEnv* env, jclass, jbyteArray input, jint format, jint width, jint height,
                          jdouble scale, jint quality, jboolean lossless) {
    return native_call(env, [&](PHImageBuffer& output, char* error, size_t capacity) {
        const auto options = image_options(format, width, height, scale, quality, lossless);
        const auto bytes = array_bytes(env, input);
        return ph_image_convert(bytes.data(), bytes.size(), &options, &output, error, capacity);
    });
}

jbyteArray native_bitmap(JNIEnv* env, jclass, jobject bitmap, jint format, jint width, jint height,
                         jdouble scale, jint quality, jboolean lossless) {
    return native_call(env, [&](PHImageBuffer& output, char* error, size_t capacity) {
        const auto options = image_options(format, width, height, scale, quality, lossless);
        const auto image = bitmap_pixels(env, bitmap);
        return ph_image_encode_rgba(image.rgba.data(), image.rgba.size(), image.width, image.height,
            static_cast<size_t>(image.width) * 4, &options, &output, error, capacity);
    });
}

}

namespace ph {

Image decode_platform(const uint8_t* data, size_t size) {
    Environment scope;
    auto* env = scope.env;
    LocalReference<jbyteArray> input(env, byte_array(env, data, size));
    LocalReference<jobject> bitmap(env, env->CallStaticObjectMethod(codecClass, decodeMethod, input.get()));
    check_java(env, "Android image decoding failed");
    auto image = bitmap_pixels(env, bitmap.get());
    env->CallVoidMethod(bitmap.get(), recycleMethod);
    check_java(env, "Cannot release decoded Bitmap");
    return apply_orientation(std::move(image), encoded_orientation(data, size));
}

std::vector<uint8_t> encode_platform(const Image& image, PHImageFormat format, int quality) {
    Environment scope;
    auto* env = scope.env;
    LocalReference<jbyteArray> pixels(env, byte_array(env, image.rgba.data(), image.rgba.size()));
    LocalReference<jbyteArray> encoded(env, static_cast<jbyteArray>(env->CallStaticObjectMethod(codecClass, encodeMethod,
        pixels.get(), static_cast<jint>(image.width), static_cast<jint>(image.height), static_cast<jint>(format), static_cast<jint>(quality))));
    check_java(env, "Android image encoding failed");
    return array_bytes(env, encoded.get());
}

}

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    LocalReference<jclass> local(env, env->FindClass("top/yayalu/imagecodec/ImageCodec"));
    LocalReference<jclass> bitmap(env, env->FindClass("android/graphics/Bitmap"));
    if (!local.get() || !bitmap.get() || env->ExceptionCheck()) return JNI_ERR;
    decodeMethod = env->GetStaticMethodID(local.get(), "decodeForNative", "([B)Landroid/graphics/Bitmap;");
    encodeMethod = env->GetStaticMethodID(local.get(), "encodeForNative", "([BIIII)[B");
    premultipliedMethod = env->GetMethodID(bitmap.get(), "isPremultiplied", "()Z");
    recycleMethod = env->GetMethodID(bitmap.get(), "recycle", "()V");
    if (!decodeMethod || !encodeMethod || !premultipliedMethod || !recycleMethod || env->ExceptionCheck()) return JNI_ERR;
    const JNINativeMethod methods[] = {
        {const_cast<char*>("nativeConvert"), const_cast<char*>("([BIIIDIZ)[B"), reinterpret_cast<void*>(native_convert)},
        {const_cast<char*>("nativeBitmap"), const_cast<char*>("(Landroid/graphics/Bitmap;IIIDIZ)[B"), reinterpret_cast<void*>(native_bitmap)}
    };
    if (env->RegisterNatives(local.get(), methods, sizeof(methods) / sizeof(methods[0])) != JNI_OK) return JNI_ERR;
    codecClass = static_cast<jclass>(env->NewGlobalRef(local.get()));
    if (!codecClass) return JNI_ERR;
    javaVM = vm;
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* vm, void*) {
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK && codecClass) env->DeleteGlobalRef(codecClass);
    codecClass = nullptr;
    javaVM = nullptr;
}
