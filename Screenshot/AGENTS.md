# ASimpleShot 应用工作流

- 使用 `Screenshot.xcodeproj` 开发截图应用。用户要求编译时，执行 `python3 /Users/allan/codes/PasteHub/scripts/build_macos.py --app Screenshot`，沿用现有固定签名证书。
- 截图全局快捷键、标注、取色、OCR、导出和截图权限设置由 ASimpleShot 管理。MozJPEG 随应用静态构建并分发上游授权文件。
- 固定签名版 Bundle ID 为 `top.yayalu.Screenshot`。macOS 已授予截图权限却提示未授权时，先检查 TCC 日志和授权记录绑定的代码签名要求。确认签名失配后，使用 `tccutil reset ScreenCapture top.yayalu.Screenshot` 重置该权限，再由用户重新授权并重启 ASimpleShot。

## Git 操作

- 遵循全局规则及用户在当前会话中的授权。提交和推送需要用户授权。
- 暂存、普通提交和普通推送遵循全局 Git 常规操作授权，适用于所有仓库、分支和远端。
- 编译、暂存、提交和推送使用独立命令。编译签名脚本使用上面的固定绝对路径。
- amend、压缩和强制推送遵循全局规则。用户明确要求本次执行时直接执行。自行决定执行时，每次均需先征得用户确认。
