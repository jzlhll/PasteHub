#!/usr/bin/env python3
"""使用 Command Line Tools 编译、打包并签名一个 macOS 应用。"""

import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
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


def load_signing(path, app_name):
    if not path.is_file():
        raise SystemExit("Local signing is not configured. Run: python3 scripts/build_macos.py "
                         f'--app {app_name} --configure-signing "PasteHub Local Signing"')
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
    parser.add_argument("--app", choices=["PasteHub", "Screenshot"], default="PasteHub")
    parser.add_argument("--resources-from", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--bundle-id")
    parser.add_argument("--signing-config", type=Path)
    parser.add_argument("--configure-signing", metavar="CERTIFICATE_NAME", help="绑定已有本机代码签名证书后退出")
    parser.add_argument("--version")
    parser.add_argument("--build-number", default="2610241")
    parser.add_argument("--executable", type=Path, help="使用已编译好的当前版本可执行文件")
    args = parser.parse_args()
    app_name = args.app
    project_root = root / app_name
    info = plistlib.loads((project_root / "Info.plist").read_bytes())
    product_name = info.get("CFBundleDisplayName", app_name)
    app_filename = product_name + ".app"
    sources = project_root / "Sources"
    has_screenshot_encoder = app_name == "Screenshot"
    default_bundle_id = "top.yayalu." + app_name
    local_signing = project_root / ".local-signing.json"
    legacy_signing = root / ".local-signing.json"
    signing_path = (args.signing_config or local_signing).expanduser().resolve()
    if args.configure_signing:
        configure_signing(signing_path, args.configure_signing, args.bundle_id or default_bundle_id)
        return
    if args.signing_config is None and not signing_path.exists() and legacy_signing.is_file():
        signing_path = legacy_signing
    identity, configured_bundle_id = load_signing(signing_path, app_name)
    resources_from = (args.resources_from or Path("/Applications") / app_filename).expanduser().resolve()
    output = (args.output or project_root / "build" / app_filename).expanduser().resolve()
    if output.suffix != ".app" or output == resources_from:
        parser.error("output must be a separate .app bundle")
    project = (project_root / (app_name + ".xcodeproj") / "project.pbxproj").read_text()
    minimum = re.search(r"MACOSX_DEPLOYMENT_TARGET = ([^;]+);", project).group(1)
    version = args.version or re.search(r"MARKETING_VERSION = ([^;]+);", project).group(1)
    if has_screenshot_encoder and signing_path == legacy_signing:
        configured_bundle_id = default_bundle_id
    bundle_id = args.bundle_id or configured_bundle_id
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        parser.error("bundle-id is invalid")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=app_name.lower() + "-build-", dir=output.parent) as temporary:
        work = Path(temporary)
        app = work / app_filename
        contents = app / "Contents"
        resources = contents / "Resources"
        executable = contents / "MacOS" / app_name
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
                       "-O", "-whole-module-optimization", "-module-name", app_name, "-o", str(executable),
                       "-Xlinker", "-dead_strip"]
            frameworks = ["AppKit", "SwiftUI", "Carbon"]
            if has_screenshot_encoder:
                mozjpeg = output.parent / "MozJPEG" / "libPasteHubMozJPEG.a"
                run(sys.executable, project_root / "scripts" / "build_mozjpeg.py", "--output", mozjpeg,
                    "--architectures", "arm64", "--deployment-target", minimum, "--sdk", sdk)
                header = project_root / "Vendor" / "MozJPEG" / "PasteHubMozJPEG.h"
                command += ["-import-objc-header", str(header), str(mozjpeg)]
                frameworks += ["ScreenCaptureKit", "Vision", "CoreImage"]
            else:
                frameworks.append("ServiceManagement")
            for framework in frameworks:
                command += ["-framework", framework]
            command += [str(path) for path in sorted(sources.rglob("*.swift"))]
            print("Compiling " + app_name + "...", flush=True)
            run(*command)
        executable.chmod(0o755)
        assets = sources / "Assets.xcassets"
        if assets.is_dir():
            actool = subprocess.run(["xcrun", "--find", "actool"], capture_output=True, text=True)
            if actool.returncode == 0:
                partial_info = work / "assets-info.plist"
                command = [actool.stdout.strip(), assets, "--compile", resources,
                           "--platform", "macosx", "--minimum-deployment-target", minimum,
                           "--app-icon", "AppIcon", "--output-partial-info-plist", partial_info]
                if (assets / "AccentColor.colorset").is_dir():
                    command += ["--accent-color", "AccentColor"]
                run(*command)
                info.update(plistlib.loads(partial_info.read_bytes()))
            else:
                source_resources = resources_from / "Contents" / "Resources"
                if not (source_resources / "Assets.car").is_file():
                    raise SystemExit("Assets.car is required. Use --resources-from with an existing " + app_filename)
                shutil.copy2(source_resources / "Assets.car", resources)
                if (source_resources / "AppIcon.icns").is_file():
                    shutil.copy2(source_resources / "AppIcon.icns", resources)
                    info["CFBundleIconFile"] = "AppIcon"
        if (sources / "Resources").is_dir():
            shutil.copytree(sources / "Resources", resources, dirs_exist_ok=True)
        info.update({"CFBundleIdentifier": bundle_id, "CFBundleName": product_name,
                     "CFBundleDisplayName": product_name, "CFBundleExecutable": app_name,
                     "CFBundlePackageType": "APPL", "CFBundleInfoDictionaryVersion": "6.0",
                     "CFBundleShortVersionString": version, "CFBundleVersion": args.build_number,
                     "LSMinimumSystemVersion": minimum,
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
