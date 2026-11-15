#!/usr/bin/env python3
"""构建指定架构的 Windows DLL，并交付头文件、导入库和授权文件。"""

import argparse
from pathlib import Path
import platform
import shutil
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["x64", "arm64"],
                        default="arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x64")
    parser.add_argument("--cmake", default=shutil.which("cmake"))
    parser.add_argument("--generator", help="Visual Studio CMake generator name")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("Build Windows DLLs on Windows with the Visual Studio C++ toolchain")
    if not args.cmake:
        parser.error("Provide --cmake or install CMake")
    target = "windows-" + args.arch
    work = root / "build" / target
    output = root / "dist" / target
    command = [args.cmake, "-S", str(root), "-B", str(work),
               "-A", "ARM64" if args.arch == "arm64" else "x64",
               "-DBUILD_SHARED_LIBS=ON", "-DCMAKE_BUILD_TYPE=MinSizeRel",
               "-DCMAKE_INSTALL_PREFIX=" + str(output)]
    if args.generator:
        command += ["-G", args.generator]
    subprocess.run(command, check=True)
    subprocess.run([args.cmake, "--build", str(work), "--config", "MinSizeRel", "--parallel", "8"], check=True)
    subprocess.run([args.cmake, "--install", str(work), "--config", "MinSizeRel"], check=True)
    library = output / "bin/PasteHubImage.dll"
    if not library.is_file() or library.stat().st_size == 0:
        raise RuntimeError("Built DLL is missing or empty: " + str(library))
    print("Built: " + str(library))


if __name__ == "__main__":
    main()
