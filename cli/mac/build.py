#!/usr/bin/env python3
"""独立编译 pastehub-image，将 libwebp 静态链接到单个 macOS 可执行文件。"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys


def build_library(root, work, architecture, minimum, sdk):
    vendor = root / "Vendor" / "libwebp"
    sources = sorted(path for folder in ["src/enc", "src/dsp", "src/utils", "sharpyuv"]
                     for path in (vendor / folder).glob("*.c"))
    inputs = [Path(__file__).resolve()] + sorted(vendor.rglob("*.c")) + sorted(vendor.rglob("*.h"))
    compiler = subprocess.check_output(["xcrun", "clang", "--version"], text=True)
    digest = hashlib.sha256(json.dumps([architecture, minimum, sdk, compiler]).encode())
    for path in inputs:
        digest.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes())
    fingerprint = digest.hexdigest()
    objects = work / architecture
    objects.mkdir(parents=True, exist_ok=True)
    library = objects / "libwebp.a"
    stamp = objects / "libwebp.sha256"
    if library.is_file() and stamp.is_file() and stamp.read_text() == fingerprint:
        print("Reusing cached libwebp for " + architecture, flush=True)
        return library

    def compile_source(path):
        target = objects / ("_".join(path.relative_to(vendor).parts) + ".o")
        subprocess.run(["xcrun", "clang", "-c", str(path), "-o", str(target),
                        "-arch", architecture, "-isysroot", sdk,
                        "-mmacosx-version-min=" + minimum, "-std=c11", "-Oz", "-DNDEBUG",
                        "-DWEBP_USE_THREAD", "-fvisibility=hidden", "-I", str(vendor)], check=True)
        return target

    print("Compiling libwebp 1.6.0 for " + architecture + "...", flush=True)
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as executor:
        compiled = list(executor.map(compile_source, sources))
    temporary = library.with_suffix(".tmp.a")
    subprocess.run(["xcrun", "libtool", "-static", "-o", str(temporary)] + [str(path) for path in compiled], check=True)
    temporary.replace(library)
    stamp.write_text(fingerprint)
    return library


def main():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architectures", nargs="+", choices=["arm64", "x86_64"], default=[platform.machine()])
    parser.add_argument("--deployment-target", default="13.0")
    parser.add_argument("--output", type=Path, default=root / "build" / "pastehub-image")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This tool requires macOS and Apple Command Line Tools")
    output = args.output.expanduser().resolve()
    work = root / "build"
    work.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    notices = "libwebp 1.6.0\nhttps://chromium.googlesource.com/webm/libwebp/+/refs/tags/v1.6.0\n\n"
    for name in ["COPYING", "PATENTS", "AUTHORS"]:
        notices += name + "\n" + (root / "Vendor" / "libwebp" / name).read_text() + "\n"
    notice_source = work / "ThirdPartyNotices.swift"
    notice_source.write_text('let thirdPartyNotices = #"""\n' + notices + '\n"""#\n')
    executables = []
    for architecture in args.architectures:
        library = build_library(root, work, architecture, args.deployment_target, sdk)
        executable = work / architecture / "pastehub-image"
        print("Compiling pastehub-image for " + architecture + "...", flush=True)
        subprocess.run(["xcrun", "swiftc", "-Osize", "-swift-version", "5", "-sdk", sdk,
                        "-target", architecture + "-apple-macos" + args.deployment_target,
                        "-module-cache-path", str(work / "ModuleCache"),
                        "-import-objc-header", str(root / "ImageCodecs.h"),
                        str(root / "main.swift"), str(notice_source), str(library),
                        "-framework", "Foundation", "-framework", "CoreGraphics",
                        "-framework", "ImageIO", "-framework", "UniformTypeIdentifiers",
                        "-Xlinker", "-dead_strip", "-o", str(executable)], check=True)
        executables.append(executable)
    temporary = output.with_name(output.name + ".tmp")
    subprocess.run(["xcrun", "lipo", "-create"] + [str(path) for path in executables]
                   + ["-output", str(temporary)], check=True)
    temporary.chmod(0o755)
    # 移除运行不需要的符号信息，再为最终文件签名。
    subprocess.run(["xcrun", "strip", str(temporary)], check=True)
    # 单文件 CLI 使用临时签名，无需应用的固定签名证书或本地配置。
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(temporary)], check=True)
    temporary.replace(output)
    print("Built: " + str(output), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        print("Build failed: " + str(error), file=sys.stderr)
        sys.exit(1)
