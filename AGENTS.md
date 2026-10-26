# PasteHub 本地工作流

- 遵循全局规则及用户在当前会话中的授权；权限规则不意味着可以主动提交或推送。
- 用户要求编译 macOS App 时，使用 `python3 /Users/allan/codes/PasteHub/scripts/build_macos.py`，沿用现有固定签名证书。
- 暂存、普通提交和普通推送遵循全局 Git 常规操作授权，适用于所有仓库，不限定 PasteHub 路径、master 或固定远端。
- 编译、暂存、提交和推送使用独立命令；只有编译签名脚本保留项目绝对路径限制。
- amend、压缩及强制推送仍遵循全局规则：只有用户主动明确要求本次执行时才直接执行；自行决定这些操作前每次都必须确认。

- macOS 已开启权限却仍提示未授权时，先检查 TCC 日志及授权记录绑定的代码签名要求，确认是否因旧证书与当前固定证书不匹配而被拒绝。确认失配后，仅用 `tccutil reset <权限服务> top.yayalu.PasteHub` 重置受影响的权限；辅助功能同时清除应用的 `accessibilityPromptedOnce` 提示缓存，再由用户重新授权并重启应用，保留签名匹配的其他权限。
