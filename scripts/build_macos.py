#!/usr/bin/env python3
"""使用 Command Line Tools 编译、打包并签名 PasteHub。"""

import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def signing_identities():
    result = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                            check=True, capture_output=True, text=True)
    return re.findall(r'\d+\) ([0-9A-Fa-f]{40}) "([^"\n]+)"', result.stdout)


def configure_signing(path, name, bundle_id):
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        raise SystemExit("Signing bundle_id is invalid")
    matches = [(fingerprint.upper(), label) for fingerprint, label in signing_identities() if label == name]
    if len(matches) != 1:
        raise SystemExit("Expected one valid code signing identity named " + repr(name)
                         + "; found " + str(len(matches)) + ". Check the certificate type, private key and trust.")
    fingerprint, name = matches[0]
    config = {"identity": fingerprint, "certificate_name": name, "bundle_id": bundle_id}
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=".signing-", delete=False) as handle:
        temporary = Path(handle.name)
        json.dump(config, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    temporary.replace(path)
    print("Pinned code signing certificate: " + name + " (" + fingerprint + ")")
    print("Local configuration: " + str(path))


def load_signing(path):
    if not path.is_file():
        raise SystemExit("Local signing is not configured. Run: python3 scripts/build_macos.py "
                         '--configure-signing "PasteHub Local Signing"')
    try:
        config = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise SystemExit("Cannot read local signing configuration: " + str(error)) from error
    if not isinstance(config, dict):
        raise SystemExit("Local signing configuration must be a JSON object")
    identity = config.get("identity", "")
    bundle_id = config.get("bundle_id", "")
    if not isinstance(identity, str) or not re.fullmatch(r"[0-9A-Fa-f]{40}", identity):
        raise SystemExit("Local signing identity must be an exact certificate SHA-1 fingerprint")
    if not isinstance(bundle_id, str) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        raise SystemExit("Local signing bundle_id is invalid")
    identity = identity.upper()
    if identity not in {fingerprint.upper() for fingerprint, _ in signing_identities()}:
        raise SystemExit("Pinned code signing certificate is unavailable: " + identity
                         + ". Restore its certificate and private key; ad hoc signing is disabled.")
    return identity, bundle_id


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources-from", type=Path, default=Path("/Applications/PasteHub.app"))
    parser.add_argument("--output", type=Path, default=root / "build" / "PasteHub.app")
    parser.add_argument("--bundle-id")
    parser.add_argument("--signing-config", type=Path, default=root / ".local-signing.json")
    parser.add_argument("--configure-signing", metavar="CERTIFICATE_NAME", help="绑定已有本机代码签名证书后退出")
    parser.add_argument("--version")
    parser.add_argument("--build-number", default="2610241")
    parser.add_argument("--executable", type=Path, help="使用已编译好的当前版本可执行文件")
    args = parser.parse_args()
    signing_path = args.signing_config.expanduser().resolve()
    if args.configure_signing:
        configure_signing(signing_path, args.configure_signing, args.bundle_id or "top.yayalu.PasteHub")
        return
    identity, configured_bundle_id = load_signing(signing_path)
    output = args.output.expanduser().resolve()
    if output.suffix != ".app" or output == args.resources_from.expanduser().resolve():
        parser.error("output must be a separate .app bundle")
    project = (root / " .xcodeproj" / "project.pbxproj").read_text()
    minimum = re.search(r"MACOSX_DEPLOYMENT_TARGET = ([^;]+);", project).group(1)
    version = args.version or re.search(r"MARKETING_VERSION = ([^;]+);", project).group(1)
    bundle_id = args.bundle_id or configured_bundle_id
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        parser.error("bundle-id is invalid")
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
        run("/usr/bin/codesign", "--force", "--sign", identity, "--identifier", bundle_id,
            "--options", "runtime", "--timestamp=none", app)
        requirement = '=identifier "' + bundle_id + '" and certificate leaf = H"' + identity + '"'
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, app)
        signature = subprocess.run(["/usr/bin/codesign", "--display", "-r", "-", str(app)],
                                   check=True, capture_output=True, text=True)
        requirements = signature.stdout + signature.stderr
        if "designated =>" not in requirements or "cdhash" in requirements:
            raise SystemExit("Expected a stable certificate-based designated requirement")
        if output.exists():
            shutil.rmtree(output)
        shutil.move(str(app), output)
    print("Built: " + str(output), flush=True)
    print("Signing certificate: " + identity, flush=True)
    print("Bundle ID: " + bundle_id, flush=True)
    print("Version: " + version + " (" + args.build_number + ")", flush=True)


if __name__ == "__main__":
    main()
