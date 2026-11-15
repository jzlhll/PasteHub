#pragma once

#include <windows.h>
#include <objbase.h>
#include <wincodec.h>

#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>

inline void checkHRESULT(HRESULT result, const char* operation) {
    if (FAILED(result)) {
        std::ostringstream message;
        message << operation << " failed (HRESULT 0x" << std::hex << std::uppercase
                << std::setw(8) << std::setfill('0') << static_cast<unsigned long>(result) << ')';
        throw std::runtime_error(message.str());
    }
}

[[noreturn]] inline void failWin32(const char* operation, DWORD error = GetLastError()) {
    throw std::runtime_error(std::string(operation) + " failed (Win32 " + std::to_string(error) + ')');
}

inline std::string utf8(const std::wstring& text) {
    if (text.empty()) return {};
    const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                                         static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (count == 0) failWin32("Convert UTF-16 to UTF-8");
    std::string result(static_cast<size_t>(count), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
                            result.data(), count, nullptr, nullptr) == 0) {
        failWin32("Convert UTF-16 to UTF-8");
    }
    return result;
}

// 管理 COM 接口的引用计数和输出参数，支持移动所有权。
template <typename T>
class ComPtr {
public:
    ComPtr() = default;
    ~ComPtr() { if (value_) value_->Release(); }
    ComPtr(const ComPtr&) = delete;
    ComPtr& operator=(const ComPtr&) = delete;
    ComPtr(ComPtr&& other) noexcept : value_(std::exchange(other.value_, nullptr)) {}
    ComPtr& operator=(ComPtr&& other) noexcept {
        if (this != &other) {
            if (value_) value_->Release();
            value_ = std::exchange(other.value_, nullptr);
        }
        return *this;
    }
    T* get() const { return value_; }
    T* operator->() const { return value_; }
    T** put() {
        if (value_) value_->Release();
        value_ = nullptr;
        return &value_;
    }
private:
    T* value_ = nullptr;
};

// 复用宿主线程已有的 COM 会话，仅撤销本库建立的初始化引用。
class ComApartment {
public:
    ComApartment() {
        const HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (result == RPC_E_CHANGED_MODE) return;
        checkHRESULT(result, "Initialize COM");
        initialized_ = true;
    }
    ~ComApartment() { if (initialized_) CoUninitialize(); }
    ComApartment(const ComApartment&) = delete;
    ComApartment& operator=(const ComApartment&) = delete;
private:
    bool initialized_ = false;
};

// 在异常路径中关闭本机文件句柄，支持在替换文件前主动释放句柄。
class FileHandle {
public:
    explicit FileHandle(HANDLE value) : value_(value) {
        if (value == INVALID_HANDLE_VALUE) failWin32("Open file");
    }
    ~FileHandle() { close(); }
    FileHandle(const FileHandle&) = delete;
    FileHandle& operator=(const FileHandle&) = delete;
    HANDLE get() const { return value_; }
    void close() {
        if (value_ != INVALID_HANDLE_VALUE) CloseHandle(std::exchange(value_, INVALID_HANDLE_VALUE));
    }
private:
    HANDLE value_;
};
