#!/usr/bin/env python3
"""构建 macOS 通用静态库与动态库；iOS 只提供构建入口，不默认构建。"""

import argparse
from pathlib import Path
import shutil
import subprocess


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["macos", "ios", "ios-simulator"], default="macos")
    parser.add_argument("--cmake", default=shutil.which("cmake"))
    parser.add_argument("--ninja", default=shutil.which("ninja"))
    args = parser.parse_args()
    if not args.cmake:
        parser.error("Provide --cmake or install CMake")
    work = root / "build" / args.platform
    output = root / "dist" / args.platform
    command = [args.cmake, "-S", str(root), "-B", str(work), "-DCMAKE_BUILD_TYPE=MinSizeRel",
               "-DCMAKE_INSTALL_PREFIX=" + str(output)]
    if args.ninja:
        command += ["-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + args.ninja]
    if args.platform == "macos":
        command += ["-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0"]
    else:
        command += ["-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0",
                    "-DCMAKE_OSX_SYSROOT=" + ("iphoneos" if args.platform == "ios" else "iphonesimulator"),
                    "-DCMAKE_OSX_ARCHITECTURES=" + ("arm64" if args.platform == "ios" else "arm64;x86_64")]
    subprocess.run(command, check=True)
    subprocess.run([args.cmake, "--build", str(work), "--parallel", "8"], check=True)
    subprocess.run([args.cmake, "--install", str(work)], check=True)
    print("Built: " + str(output / "lib/libPasteHubImage.a"))
    if args.platform == "macos":
        print("Built: " + str(output / "lib/libPasteHubImage.dylib"))


if __name__ == "__main__":
    main()
