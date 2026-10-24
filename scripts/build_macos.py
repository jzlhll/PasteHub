#!/usr/bin/env python3
"""使用 Command Line Tools 编译、打包并签名 PasteHub。"""

import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources-from", type=Path, default=Path("/Applications/PasteHub.app"))
    parser.add_argument("--output", type=Path, default=root / "build" / "PasteHub.app")
    parser.add_argument("--bundle-id")
    parser.add_argument("--version")
    parser.add_argument("--build-number", default="2610241")
    parser.add_argument("--executable", type=Path, help="使用已编译好的当前版本可执行文件")
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output.suffix != ".app" or output == args.resources_from.expanduser().resolve():
        parser.error("output must be a separate .app bundle")
    project = (root / " .xcodeproj" / "project.pbxproj").read_text()
    minimum = re.search(r"MACOSX_DEPLOYMENT_TARGET = ([^;]+);", project).group(1)
    version = args.version or re.search(r"MARKETING_VERSION = ([^;]+);", project).group(1)
    installed_info = args.resources_from / "Contents" / "Info.plist"
    old_info = plistlib.loads(installed_info.read_bytes()) if installed_info.exists() else {}
    bundle_id = args.bundle_id or old_info.get("CFBundleIdentifier", "com.example.PasteHub")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pastehub-build-", dir=output.parent) as temporary:
        work = Path(temporary)
        app = work / "PasteHub.app"
        contents = app / "Contents"
        resources = contents / "Resources"
        executable = contents / "MacOS" / "PasteHub"
        resources.mkdir(parents=True)
        executable.parent.mkdir(parents=True)
        if args.executable:
            shutil.copy2(args.executable, executable)
        else:
            command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                       "-default-isolation", "MainActor", "-enable-upcoming-feature",
                       "NonisolatedNonsendingByDefault", "-enable-upcoming-feature",
                       "InferIsolatedConformances", "-enable-upcoming-feature", "MemberImportVisibility",
                       "-target", "arm64-apple-macos" + minimum, "-sdk", sdk,
                       "-module-cache-path", str(output.parent / "ModuleCache"),
                       "-O", "-whole-module-optimization", "-module-name", "PasteHub", "-o", str(executable)]
            for framework in ["AppKit", "SwiftUI", "Carbon", "ScreenCaptureKit", "ServiceManagement"]:
                command += ["-framework", framework]
            command += [str(path) for path in sorted((root / "PasteHub").rglob("*.swift"))]
            print("Compiling PasteHub...", flush=True)
            run(*command)
        executable.chmod(0o755)
        actool = subprocess.run(["xcrun", "--find", "actool"], capture_output=True, text=True)
        if actool.returncode == 0:
            run(actool.stdout.strip(), root / "PasteHub" / "Assets.xcassets", "--compile", resources,
                "--platform", "macosx", "--minimum-deployment-target", minimum,
                "--app-icon", "AppIcon", "--accent-color", "AccentColor",
                "--output-partial-info-plist", work / "assets-info.plist")
        else:
            # 独立命令行工具不含 actool，沿用已安装应用的资源目录。
            source_resources = args.resources_from / "Contents" / "Resources"
            if not (source_resources / "Assets.car").is_file():
                raise SystemExit("Assets.car is required. Use --resources-from with an existing PasteHub.app.")
            shutil.copytree(source_resources, resources, dirs_exist_ok=True)
        info = plistlib.loads((root / "Info.plist").read_bytes())
        info.update({"CFBundleIdentifier": bundle_id, "CFBundleName": "PasteHub",
                     "CFBundleDisplayName": "PasteHub", "CFBundleExecutable": "PasteHub",
                     "CFBundlePackageType": "APPL", "CFBundleInfoDictionaryVersion": "6.0",
                     "CFBundleShortVersionString": version, "CFBundleVersion": args.build_number,
                     "CFBundleIconFile": "AppIcon", "LSMinimumSystemVersion": minimum,
                     "LSApplicationCategoryType": "public.app-category.utilities",
                     "NSHighResolutionCapable": True})
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        (contents / "PkgInfo").write_bytes(b"APPL????")
        run("codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none", app)
        run("codesign", "--verify", "--deep", "--strict", app)
        if output.exists():
            shutil.rmtree(output)
        shutil.move(str(app), output)
    print("Built: " + str(output), flush=True)
    print("Bundle ID: " + bundle_id, flush=True)
    print("Version: " + version + " (" + args.build_number + ")", flush=True)


if __name__ == "__main__":
    main()
