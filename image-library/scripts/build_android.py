#!/usr/bin/env python3
"""通过 Gradle 构建 AAR，并将交付文件复制到 dist/android。"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--maven-mirror", help="Optional Maven mirror root containing google and public repositories")
    args = parser.parse_args()
    project = root / "android"
    if args.sdk:
        (project / "local.properties").write_text("sdk.dir=" + args.sdk.expanduser().resolve().as_posix() + "\n")
    wrapper = project / ("gradlew.bat" if os.name == "nt" else "gradlew")
    command = [str(wrapper), ":imagecodec:assembleRelease", "--no-daemon", "--console=plain"]
    if args.offline:
        command.append("--offline")
    if args.maven_mirror:
        command.append("-PpastehubMavenMirror=" + args.maven_mirror.rstrip("/"))
    subprocess.run(command, cwd=project, check=True)
    output = root / "dist" / "android" / "pastehub-image-1.0.0.aar"
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(project / "imagecodec/build/outputs/aar/imagecodec-release.aar", output)
    print("Built: " + str(output))


if __name__ == "__main__":
    main()
