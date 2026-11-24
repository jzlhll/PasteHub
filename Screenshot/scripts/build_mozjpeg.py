#!/usr/bin/env python3
"""使用 Apple Clang 编译仓库内的 MozJPEG，供 Xcode 和命令行构建共用。"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess


def build(output, architectures, minimum, sdk):
    root = Path(__file__).resolve().parent.parent
    vendor = root / "Vendor" / "MozJPEG"
    source = vendor / "src"
    sdk = str(Path(sdk).resolve())
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    inputs = [Path(__file__).resolve()] + sorted(path for path in vendor.rglob("*")
                                                if path.is_file() and path.suffix in [".c", ".h"])
    compiler = subprocess.check_output(["xcrun", "clang", "--version"], text=True)
    settings = {"architectures": architectures, "minimum": minimum, "sdk": sdk, "compiler": compiler}
    digest = hashlib.sha256(json.dumps(settings, sort_keys=True).encode())
    for path in inputs:
        digest.update(str(path.relative_to(root)).encode() + b"\0")
        digest.update(path.read_bytes())
    fingerprint = digest.hexdigest()
    stamp = output.with_suffix(".sha256")
    if output.is_file() and stamp.is_file():
        if stamp.read_text() == fingerprint:
            print("Reusing cached MozJPEG library", flush=True)
            return output

    sources = sorted(source.glob("*.c")) + [vendor / "PasteHubMozJPEG.c"]
    libraries = []
    print("Compiling MozJPEG 4.1.5...", flush=True)
    for architecture in architectures:
        objects = output.parent / architecture
        objects.mkdir(parents=True, exist_ok=True)

        def compile_source(path):
            target = objects / (path.stem + ".o")
            subprocess.run(["xcrun", "clang", "-c", str(path), "-o", str(target),
                            "-arch", architecture, "-isysroot", sdk,
                            "-mmacosx-version-min=" + minimum, "-std=c11", "-O2", "-DNDEBUG",
                            "-fvisibility=hidden", "-I", str(source), "-I", str(source / "include")], check=True)
            return target

        with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as executor:
            compiled = list(executor.map(compile_source, sources))
        library = objects / "libPasteHubMozJPEG.a"
        subprocess.run(["xcrun", "libtool", "-static", "-o", str(library)] + [str(path) for path in compiled], check=True)
        libraries.append(library)
    temporary = output.with_suffix(".tmp.a")
    subprocess.run(["xcrun", "lipo", "-create"] + [str(path) for path in libraries] + ["-output", str(temporary)], check=True)
    temporary.replace(output)
    stamp.write_text(fingerprint)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--architectures", nargs="+", choices=["arm64", "x86_64"], required=True)
    parser.add_argument("--deployment-target", required=True)
    parser.add_argument("--sdk", required=True)
    args = parser.parse_args()
    build(args.output, args.architectures, args.deployment_target, args.sdk)


if __name__ == "__main__":
    main()
